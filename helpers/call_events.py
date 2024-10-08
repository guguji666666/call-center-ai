import asyncio
from collections.abc import AsyncGenerator, Awaitable, Callable

from azure.communication.callautomation import (
    AzureBlobContainerRecordingStorage,
    DtmfTone,
    MediaStreamingAudioChannelType,
    MediaStreamingContentType,
    MediaStreamingOptions,
    MediaStreamingTransportType,
    RecognitionChoice,
    RecordingChannel,
    RecordingContent,
    RecordingFormat,
)
from azure.communication.callautomation.aio import CallAutomationClient
from azure.core.exceptions import ClientAuthenticationError, HttpResponseError
from pydantic import ValidationError

from helpers.call_llm import load_llm_chat
from helpers.call_utils import (
    ContextEnum as CallContextEnum,
    handle_hangup,
    handle_play_text,
    handle_recognize_ivr,
    handle_transfer,
    start_audio_streaming,
)
from helpers.config import CONFIG
from helpers.features import recording_enabled, voice_recognition_retry_max
from helpers.llm_worker import completion_sync
from helpers.logging import logger
from helpers.monitoring import CallAttributes, span_attribute, tracer
from models.call import CallStateModel
from models.message import (
    ActionEnum as MessageActionEnum,
    MessageModel,
    PersonaEnum as MessagePersonaEnum,
    StyleEnum as MessageStyleEnum,
    extract_message_style,
    remove_message_action,
)
from models.next import NextModel
from models.synthesis import SynthesisModel

_sms = CONFIG.sms.instance()
_db = CONFIG.database.instance()


@tracer.start_as_current_span("on_new_call")
async def on_new_call(
    callback_url: str,
    client: CallAutomationClient,
    incoming_context: str,
    phone_number: str,
    wss_url: str,
) -> bool:
    logger.debug("Incoming call handler caller ID: %s", phone_number)

    streaming_options = MediaStreamingOptions(
        audio_channel_type=MediaStreamingAudioChannelType.UNMIXED,
        content_type=MediaStreamingContentType.AUDIO,
        start_media_streaming=False,
        transport_type=MediaStreamingTransportType.WEBSOCKET,
        transport_url=wss_url,
    )

    try:
        answer_call_result = await client.answer_call(
            callback_url=callback_url,
            cognitive_services_endpoint=CONFIG.cognitive_service.endpoint,
            incoming_call_context=incoming_context,
            media_streaming=streaming_options,
        )
        logger.info(
            "Answered call with %s (%s)",
            phone_number,
            answer_call_result.call_connection_id,
        )
        return True

    except ClientAuthenticationError:
        logger.error(
            "Authentication error with Communication Services, check the credentials",
            exc_info=True,
        )

    except HttpResponseError as e:
        if "lifetime validation of the signed http request failed" in e.message.lower():
            logger.debug("Old call event received, ignoring")
        else:
            logger.error(
                "Unknown error answering call with %s",
                phone_number,
                exc_info=True,
            )

    return False


@tracer.start_as_current_span("on_call_connected")
async def on_call_connected(
    call: CallStateModel,
    client: CallAutomationClient,
    post_callback: Callable[[CallStateModel], Awaitable[None]],
    server_call_id: str,
    training_callback: Callable[[CallStateModel], Awaitable[None]],
) -> None:
    logger.info("Call connected, asking for language")
    call.recognition_retry = 0  # Reset recognition retry counter
    call.messages.append(
        MessageModel(
            action=MessageActionEnum.CALL,
            content="",
            persona=MessagePersonaEnum.HUMAN,
        )
    )
    await asyncio.gather(
        _handle_ivr_language(
            call=call,
            client=client,
        ),  # First, every time a call is answered, confirm the language
        _db.call_aset(
            call
        ),  # Second, save in DB allowing SMS answers to be more "in-sync", should be quick enough to be in sync with the next message
        _handle_recording(
            call=call,
            client=client,
            server_call_id=server_call_id,
        ),  # Third, start recording the call
    )


@tracer.start_as_current_span("on_call_disconnected")
async def on_call_disconnected(
    call: CallStateModel,
    client: CallAutomationClient,
    post_callback: Callable[[CallStateModel], Awaitable[None]],
) -> None:
    logger.info("Call disconnected")
    await _handle_hangup(
        call=call,
        client=client,
        post_callback=post_callback,
    )


@tracer.start_as_current_span("on_audio_connected")
async def on_audio_connected(
    call: CallStateModel,
    channels: int,
    client: CallAutomationClient,
    encoding: str,
    in_audio: AsyncGenerator[bytes, None],
    length: int,
    post_callback: Callable[[CallStateModel], Awaitable[None]],
    sample_rate: int,
    training_callback: Callable[[CallStateModel], Awaitable[None]],
) -> None:
    # Check if the audio is supported
    # TODO: If Communication Services sends audio in a format that is not supported, we should convert it on the fly
    if encoding != "pcm":
        logger.error("Unsupported audio encoding %s", encoding)
        return
    if channels != 1:
        logger.error("Unsupported audio channels %s", channels)
        return

    await load_llm_chat(
        audio_length=length,
        audio_sample_rate=sample_rate,
        audio_stream=in_audio,
        automation_client=client,
        call=call,
        post_callback=post_callback,
        training_callback=training_callback,
    )


@tracer.start_as_current_span("on_recognize_timeout_error")
async def on_recognize_timeout_error(
    call: CallStateModel,
    client: CallAutomationClient,
    contexts: set[CallContextEnum] | None,
    post_callback: Callable[[CallStateModel], Awaitable[None]],
    training_callback: Callable[[CallStateModel], Awaitable[None]],
) -> None:
    if (
        contexts and CallContextEnum.IVR_LANG_SELECT in contexts
    ):  # Retry IVR recognition
        span_attribute(CallAttributes.CALL_CHANNEL, "ivr")
        if call.recognition_retry < await voice_recognition_retry_max():
            call.recognition_retry += 1
            logger.info(
                "Timeout, retrying language selection (%s/%s)",
                call.recognition_retry,
                await voice_recognition_retry_max(),
            )
            await _handle_ivr_language(
                call=call,
                client=client,
                post_callback=post_callback,
                training_callback=training_callback,
            )
        else:  # IVR retries are exhausted, end call
            logger.info("Timeout, ending call")
            await _handle_goodbye(
                call=call,
                client=client,
            )
        return

    if (
        call.recognition_retry >= await voice_recognition_retry_max()
    ):  # Voice retries are exhausted, end call
        logger.info("Timeout, ending call")
        await _handle_goodbye(
            call=call,
            client=client,
        )
        return


async def _handle_goodbye(
    call: CallStateModel,
    client: CallAutomationClient,
) -> None:
    await handle_play_text(
        call=call,
        client=client,
        context=CallContextEnum.GOODBYE,
        store=False,  # Do not store timeout prompt as it perturbs the LLM and makes it hallucinate
        text=await CONFIG.prompts.tts.goodbye(call),
    )


@tracer.start_as_current_span("on_recognize_unknown_error")
async def on_recognize_unknown_error(
    call: CallStateModel,
    client: CallAutomationClient,
    error_code: int,
) -> None:
    span_attribute(CallAttributes.CALL_CHANNEL, "voice")

    if error_code == 8511:  # noqa: PLR2004
        # Failure while trying to play the prompt
        logger.warning("Failed to play prompt")
    else:
        logger.warning(
            "Recognition failed with unknown error code %s, answering with default error",
            error_code,
        )

    # Never store the error message in the call history, it has caused hallucinations in the LLM
    await handle_recognize_text(
        call=call,
        client=client,
        no_response_error=True,
        store=False,
        text=await CONFIG.prompts.tts.error(call),
    )


@tracer.start_as_current_span("on_play_completed")
async def on_play_completed(
    call: CallStateModel,
    client: CallAutomationClient,
    contexts: set[CallContextEnum] | None,
    post_callback: Callable[[CallStateModel], Awaitable[None]],
) -> None:
    logger.debug("Play completed")
    span_attribute(CallAttributes.CALL_CHANNEL, "voice")

    if not contexts:
        return

    if (
        CallContextEnum.TRANSFER_FAILED in contexts
        or CallContextEnum.GOODBYE in contexts
    ):  # Call ended
        logger.info("Ending call")
        await _handle_hangup(
            call=call,
            client=client,
            post_callback=post_callback,
        )

    elif CallContextEnum.CONNECT_AGENT in contexts:  # Call transfer
        logger.info("Initiating transfer call initiated")
        await handle_transfer(
            call=call,
            client=client,
            target=call.initiate.agent_phone_number,
        )


@tracer.start_as_current_span("on_play_error")
async def on_play_error(error_code: int) -> None:
    logger.debug("Play failed")
    span_attribute(CallAttributes.CALL_CHANNEL, "voice")
    # See: https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/communication-services/how-tos/call-automation/play-action.md
    if error_code == 8535:  # noqa: PLR2004
        # Action failed, file format
        logger.warning("Error during media play, file format is invalid")
    elif error_code == 8536:  # noqa: PLR2004
        # Action failed, file downloaded
        logger.warning("Error during media play, file could not be downloaded")
    elif error_code == 8565:  # noqa: PLR2004
        # Action failed, AI services config
        logger.error(
            "Error during media play, impossible to connect with Azure AI services"
        )
    elif error_code == 9999:  # noqa: PLR2004
        # Unknown error code
        logger.warning("Error during media play, unknown internal server error")
    else:
        logger.warning("Error during media play, unknown error code %s", error_code)


@tracer.start_as_current_span("on_ivr_recognized")
async def on_ivr_recognized(
    call: CallStateModel,
    client: CallAutomationClient,
    label: str,
) -> None:
    logger.info("IVR recognized: %s", label)
    span_attribute(CallAttributes.CALL_CHANNEL, "ivr")
    span_attribute(CallAttributes.CALL_MESSAGE, label)
    call.recognition_retry = 0  # Reset recognition retry counter
    try:
        lang = next(
            (x for x in call.initiate.lang.availables if x.short_code == label),
            call.initiate.lang.default_lang,
        )
    except ValueError:
        logger.warning("Unknown IVR %s, code not implemented", label)
        return

    logger.info("Setting call language to %s", lang)
    call.lang = lang.short_code
    persist_coro = _db.call_aset(call)

    if len(call.messages) <= 1:  # First call, or only the call action
        await asyncio.gather(
            handle_play_text(
                call=call,
                client=client,
                text=await CONFIG.prompts.tts.hello(call),
            ),  # First, greet the user
            persist_coro,  # Second, persist language change for next messages, should be quick enough to be in sync with the next message
            start_audio_streaming(
                call=call,
                client=client,
            ),  # Third, the conversation with the LLM should start
        )  # All in parallel to lower the response latency

    else:  # Returning call
        await asyncio.gather(
            handle_play_text(
                call=call,
                client=client,
                style=MessageStyleEnum.CHEERFUL,
                text=await CONFIG.prompts.tts.welcome_back(call),
            ),  # First, welcome back the user
            persist_coro,  # Second, persist language change for next messages, should be quick enough to be in sync with the next message
            start_audio_streaming(
                call=call,
                client=client,
            ),  # Third, the conversation with the LLM should start
        )


@tracer.start_as_current_span("on_transfer_completed")
async def on_transfer_completed() -> None:
    logger.info("Call transfer accepted event")
    # TODO: Is there anything to do here?


@tracer.start_as_current_span("on_transfer_error")
async def on_transfer_error(
    call: CallStateModel,
    client: CallAutomationClient,
    error_code: int,
) -> None:
    logger.info("Error during call transfer, subCode %s", error_code)
    await handle_play_text(
        call=call,
        client=client,
        context=CallContextEnum.TRANSFER_FAILED,
        text=await CONFIG.prompts.tts.calltransfer_failure(call),
    )


@tracer.start_as_current_span("on_sms_received")
async def on_sms_received(
    call: CallStateModel,
    client: CallAutomationClient,
    message: str,
    post_callback: Callable[[CallStateModel], Awaitable[None]],
    training_callback: Callable[[CallStateModel], Awaitable[None]],
) -> bool:
    logger.info("SMS received from %s: %s", call.initiate.phone_number, message)
    span_attribute(CallAttributes.CALL_CHANNEL, "sms")
    span_attribute(CallAttributes.CALL_MESSAGE, message)
    call.messages.append(
        MessageModel(
            action=MessageActionEnum.SMS,
            content=message,
            persona=MessagePersonaEnum.HUMAN,
        )
    )
    await _db.call_aset(call)  # save in DB allowing SMS answers to be more "in-sync"
    if not call.in_progress:
        logger.info("Call not in progress, answering with SMS")
    else:
        logger.info("Call in progress, answering with voice")
        # await load_llm_chat(
        #     call=call,
        #     client=client,
        #     post_callback=post_callback,
        #     training_callback=training_callback,
        # )
    return True


async def _handle_hangup(
    call: CallStateModel,
    client: CallAutomationClient,
    post_callback: Callable[[CallStateModel], Awaitable[None]],
) -> None:
    await handle_hangup(client=client, call=call)
    call.messages.append(
        MessageModel(
            action=MessageActionEnum.HANGUP,
            content="",
            persona=MessagePersonaEnum.HUMAN,
        )
    )
    await post_callback(call)


async def on_end_call(
    call: CallStateModel,
) -> None:
    """
    Shortcut to run all post-call intelligence tasks in background.
    """
    if (
        len(call.messages) >= 3  # noqa: PLR2004
        and call.messages[-3].action == MessageActionEnum.CALL
        and call.messages[-2].persona == MessagePersonaEnum.ASSISTANT
        and call.messages[-1].action == MessageActionEnum.HANGUP
    ):
        logger.info(
            "Call ended before any interaction, skipping post-call intelligence"
        )
        return

    await asyncio.gather(
        _intelligence_next(call),
        _intelligence_sms(call),
        _intelligence_synthesis(call),
    )


async def _intelligence_sms(call: CallStateModel) -> None:
    """
    Send an SMS report to the customer.
    """

    def _validate(req: str | None) -> tuple[bool, str | None, str | None]:
        if not req:
            return False, "No SMS content", None
        return True, None, req

    content = await completion_sync(
        res_type=str,
        system=CONFIG.prompts.llm.sms_summary_system(call),
        validation_callback=_validate,
    )

    # Delete action and style from the message as they are in the history and LLM hallucinates them
    _, content = extract_message_style(remove_message_action(content or ""))

    if not content:
        logger.warning("Error generating SMS report")
        return
    logger.info("SMS report: %s", content)

    # Send the SMS to both the current caller and the policyholder
    success = False
    for number in set(
        [call.initiate.phone_number, call.claim.get("policyholder_phone", None)]
    ):
        if not number:
            continue
        res = await _sms.asend(content, number)
        if not res:
            logger.warning("Failed sending SMS report to %s", number)
            continue
        success = True

    if success:
        call.messages.append(
            MessageModel(
                action=MessageActionEnum.SMS,
                content=content,
                persona=MessagePersonaEnum.ASSISTANT,
            )
        )
        await _db.call_aset(call)


async def _intelligence_synthesis(call: CallStateModel) -> None:
    """
    Synthesize the call and store it to the model.
    """
    logger.debug("Synthesizing call")

    def _validate(
        req: str | None,
    ) -> tuple[bool, str | None, SynthesisModel | None]:
        if not req:
            return False, "Empty response", None
        try:
            return True, None, SynthesisModel.model_validate_json(req)
        except ValidationError as e:
            return False, str(e), None

    model = await completion_sync(
        res_type=SynthesisModel,
        system=CONFIG.prompts.llm.synthesis_system(call),
        validate_json=True,
        validation_callback=_validate,
    )
    if not model:
        logger.warning("Error generating synthesis")
        return

    logger.info("Synthesis: %s", model)
    call.synthesis = model
    await _db.call_aset(call)


async def _intelligence_next(call: CallStateModel) -> None:
    """
    Generate next action for the call.
    """
    logger.debug("Generating next action")

    def _validate(
        req: str | None,
    ) -> tuple[bool, str | None, NextModel | None]:
        if not req:
            return False, "Empty response", None
        try:
            return True, None, NextModel.model_validate_json(req)
        except ValidationError as e:
            return False, str(e), None

    model = await completion_sync(
        res_type=NextModel,
        system=CONFIG.prompts.llm.next_system(call),
        validate_json=True,
        validation_callback=_validate,
    )
    if not model:
        logger.warning("Error generating next action")
        return

    logger.info("Next action: %s", model)
    call.next = model
    await _db.call_aset(call)


async def _handle_ivr_language(
    call: CallStateModel,
    client: CallAutomationClient,
) -> None:
    # If only one language is available, skip the IVR
    if len(CONFIG.conversation.initiate.lang.availables) == 1:
        short_code = CONFIG.conversation.initiate.lang.availables[0].short_code
        logger.info("Only one language available, selecting %s by default", short_code)
        await on_ivr_recognized(
            call=call,
            client=client,
            label=short_code,
        )
        return

    tones = [
        DtmfTone.ONE,
        DtmfTone.TWO,
        DtmfTone.THREE,
        DtmfTone.FOUR,
        DtmfTone.FIVE,
        DtmfTone.SIX,
        DtmfTone.SEVEN,
        DtmfTone.EIGHT,
        DtmfTone.NINE,
    ]
    choices = []
    for i, lang in enumerate(CONFIG.conversation.initiate.lang.availables):
        choices.append(
            RecognitionChoice(
                label=lang.short_code,
                phrases=lang.pronunciations_en,
                tone=tones[i],
            )
        )
    await handle_recognize_ivr(
        call=call,
        choices=choices,
        client=client,
        context=CallContextEnum.IVR_LANG_SELECT,
        text=await CONFIG.prompts.tts.ivr_language(call),
    )


async def _handle_recording(
    call: CallStateModel,
    client: CallAutomationClient,
    server_call_id: str,
) -> None:
    if not await recording_enabled():
        return

    assert CONFIG.communication_services.recording_container_url
    recording = await client.start_recording(
        recording_channel_type=RecordingChannel.UNMIXED,
        recording_content_type=RecordingContent.AUDIO,
        recording_format_type=RecordingFormat.WAV,
        server_call_id=server_call_id,
        recording_storage=AzureBlobContainerRecordingStorage(
            CONFIG.communication_services.recording_container_url
        ),
    )
    logger.info(
        "Recording started for %s (%s)",
        call.initiate.phone_number,
        recording.recording_id,
    )

"""
Voice service abstract class
"""


class Voice extends object {
    fn voiceToText(voice_file) {
        """
        Send voice to voice service and get text
        """
        raise NotImplementedError

    }
    fn textToVoice(text) {
        """
        Send text to voice service and get voice
        """
        raise NotImplementedError
    }
}
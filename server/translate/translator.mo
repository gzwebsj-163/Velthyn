"""
Voice service abstract class
"""


class Translator extends object {
    # please use https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes to specify language
    fn translate(query, from_lang = "", to_lang = "en") {
        """
        Translate text from one language to another
        """
        raise NotImplementedError
    }
}
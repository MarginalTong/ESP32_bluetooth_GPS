import base64
import io
import unittest
import wave
from server import validate_audio_request, validate_audio_result


class AudioChecks(unittest.TestCase):
    def test_nearby_schema(self):
        result = {'intent': 'find_nearby', 'destination': '', 'category': 'fuel', 'brand': 'BP'}
        self.assertEqual(validate_audio_result(result), {**result, 'utterance': ''})
        for field, value in [('category', 'cheapest'), ('brand', 'https://example.com'), ('destination', 'invented address')]:
            with self.assertRaises(ValueError):
                validate_audio_result(dict(result, **{field: value}))

    def audio(self, rate=16000):
        out = io.BytesIO()
        with wave.open(out, 'wb') as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes(b'\0\0' * 16000)
        return {'audio': base64.b64encode(out.getvalue()).decode(), 'context': 'request'}

    def test_valid_wav(self):
        self.assertEqual(validate_audio_request(self.audio())['context'], 'request')

    def test_invalid_format(self):
        for data in [self.audio(8000), {'audio': 'broken', 'context': 'request'},
                     {'audio': 'AAAA', 'context': 'execute'}, {}]:
            with self.assertRaises(ValueError):
                validate_audio_request(data)

    def test_history_turns_are_bounded(self):
        ok = dict(self.audio(), history=[{'user': 'hi', 'assistant': 'hello'}])
        self.assertEqual(validate_audio_request(ok)['context'], 'request')
        for turn in [{'user': 'x' * 161, 'assistant': ''},
                     {'user': '', 'assistant': 'x' * 241},
                     {'user': 'a\nb', 'assistant': ''},
                     {'user': 1, 'assistant': ''}]:
            with self.assertRaises(ValueError):
                validate_audio_request(dict(self.audio(), history=[turn]))

    def test_result_schema(self):
        self.assertEqual(validate_audio_result({'intent': 'avoid_tolls', 'destination': ''})['intent'], 'avoid_tolls')
        for result in [{'intent': 'change_destination', 'destination': ''},
                       {'intent': 'repeat', 'destination': 'Sydney'},
                       {'intent': 'drive_now', 'destination': ''},
                       {'intent': 'change_destination', 'destination': 'https://example.com'}]:
            with self.assertRaises(ValueError):
                validate_audio_result(result)

import unittest
import json
from unittest.mock import patch, MagicMock
from server import Budget, Handler, classify_audio, converse_audio, validate_audio_result, validate_reply_request, draft_reply

class GatewayTests(unittest.TestCase):
    def test_conversation_has_no_intent_or_route_action(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps({'candidates': [{
            'finishReason': 'STOP', 'content': {'parts': [{'text': json.dumps({
                'utterance': 'hello', 'reply': 'Hello, how are you?',
                'action': 'none', 'argument': '', 'decision': 'none'
            })}]}
        }]}).encode()
        with patch('server.urllib.request.urlopen', return_value=response) as send:
            result = converse_audio({'audio': 'test', 'context': 'request', 'history': []}, 'key', 'model')
        self.assertEqual(result, {'utterance': 'hello', 'reply': 'Hello, how are you?',
                                  'action': 'none', 'argument': '', 'decision': 'none',
                                  'intent': 'chat', 'destination': ''})
        schema = json.loads(send.call_args.args[0].data)['generationConfig']['responseSchema']
        self.assertEqual(set(schema['properties']), {'utterance', 'reply', 'action', 'argument', 'decision'})

    def test_saved_place_action_requires_available_slot(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps({'candidates': [{
            'finishReason': 'STOP', 'content': {'parts': [{'text': json.dumps({
                'utterance': 'take me home', 'reply': 'I can help with that.',
                'action': 'saved_place', 'argument': 'home', 'decision': 'none'
            })}]}
        }]}).encode()
        with patch('server.urllib.request.urlopen', return_value=response):
            accepted = converse_audio({'audio': 'test', 'context': 'request',
                                      'saved_slots': ['home'], 'trip_access': True}, 'key', 'model')
            self.assertEqual(accepted['action'], 'saved_place')
            with self.assertRaises(ValueError):
                converse_audio({'audio': 'test', 'context': 'request',
                                'saved_slots': [], 'trip_access': True}, 'key', 'model')

    def test_audio_schema_has_no_empty_enum_and_keeps_empty_category(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps({'candidates': [{
            'finishReason': 'STOP',
            'content': {'parts': [{'text': json.dumps({
                'intent': 'repeat', 'utterance': 'say it again', 'reply': '', 'destination': '', 'category': '', 'brand': ''
            })}]}
        }]}).encode()
        with patch('server.urllib.request.urlopen', return_value=response) as send:
            result = classify_audio({'audio': 'test', 'context': 'request'}, 'test-key', 'test-model')
        self.assertEqual(result, {'intent': 'repeat', 'destination': '', 'utterance': 'say it again'})
        payload = json.loads(send.call_args.args[0].data)
        schema = payload['generationConfig']['responseSchema']
        for field in schema['properties'].values():
            self.assertNotIn('', field.get('enum', []))
        self.assertIn('category', schema['required'])

    def test_category_allowlist_is_still_enforced(self):
        for category in ('', 'hospital', 'invented'):
            with self.assertRaises(ValueError):
                validate_audio_result({'intent': 'find_nearby', 'destination': '',
                                       'category': category, 'brand': ''})
        self.assertEqual(validate_audio_result({
            'intent': 'find_nearby', 'destination': '', 'category': 'fuel', 'brand': 'BP'
        })['category'], 'fuel')
        with self.assertRaises(ValueError):
            validate_audio_result({'intent': 'repeat', 'destination': '',
                                   'category': 'fuel', 'brand': ''})

    def test_greeting_is_conversational_but_cannot_invent_a_turn(self):
        self.assertEqual(validate_audio_result({
            'intent': 'greeting', 'utterance': 'hi', 'reply': 'Hi! How can I help?',
            'destination': '', 'category': '', 'brand': ''})['reply'],
            'Hi! How can I help?')
        with self.assertRaises(ValueError):
            validate_audio_result({'intent': 'greeting', 'utterance': 'hi',
                                   'reply': 'Turn left now.', 'destination': '',
                                   'category': '', 'brand': ''})

    def test_chat_accepts_social_reply_but_rejects_navigation_claim(self):
        self.assertEqual(validate_audio_result({
            'intent': 'chat', 'utterance': 'I like riding',
            'reply': 'That sounds fun. What do you enjoy most?',
            'destination': '', 'category': '', 'brand': ''})['intent'], 'chat')
        with self.assertRaises(ValueError):
            validate_audio_result({'intent': 'chat', 'utterance': 'hello',
                                   'reply': 'Turn right now.', 'destination': '',
                                   'category': '', 'brand': ''})

    def test_retired_text_endpoint_is_not_served(self):
        handler = object.__new__(Handler)
        handler.path = '/v1/intent-test'
        replies = []
        handler.reply = lambda code, body: replies.append((code, body))
        handler.do_POST()
        self.assertEqual(replies, [(404, {'error': 'not_found'})])

    def test_limits(self):
        budget = Budget(':memory:', daily=2, per_minute=1)
        self.assertTrue(budget.take(100))
        self.assertFalse(budget.take(101))
        self.assertTrue(budget.take(161))
        self.assertFalse(budget.take(222))
        self.assertTrue(budget.take(90000))

    def test_verified_reply_rejects_new_navigation_claim_without_fact(self):
        value = validate_reply_request({'intent': 'repeat', 'fact': 'Turn right in 200 metres.',
                                        'language': 'en', 'previous': '', 'utterance': 'say it again'})
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps({'candidates': [{
            'finishReason': 'STOP', 'content': {'parts': [{'text': 'Turn left now.'}]}
        }]}).encode()
        with patch('server.urllib.request.urlopen', return_value=response):
            with self.assertRaises(ValueError):
                draft_reply(value, 'test-key', 'test-model')
        response.read.return_value = json.dumps({'candidates': [{
            'finishReason': 'STOP', 'content': {'parts': [{'text': 'Sure. Turn right in 200 metres.'}]}
        }]}).encode()
        with patch('server.urllib.request.urlopen', return_value=response):
            self.assertEqual(draft_reply(value, 'test-key', 'test-model')['reply'],
                             'Sure. Turn right in 200 metres.')

if __name__ == '__main__':
    unittest.main()

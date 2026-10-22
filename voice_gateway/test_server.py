import os
import sqlite3
import tempfile
import threading
import time
import unittest
import json
from unittest.mock import patch, MagicMock
from server import Budget, Handler, manage_users, classify_audio, converse_audio, validate_audio_result, validate_reply_request, draft_reply

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

    def test_user_limits(self):
        budget = Budget(':memory:')
        user = budget.authenticate('Bearer ' + budget.add_user('alice', daily=2, per_minute=1))
        self.assertIsNone(budget.take(user, 100))
        self.assertEqual(budget.take(user, 101), 'user_limit_reached')
        self.assertIsNone(budget.take(user, 161))
        self.assertEqual(budget.take(user, 222), 'user_limit_reached')
        self.assertIsNone(budget.take(user, 90000))

    def test_one_user_cannot_spend_another_users_quota(self):
        # The point of personal tokens: a leaked or busy token only exhausts
        # its own budget.
        budget = Budget(':memory:')
        alice = budget.authenticate('Bearer ' + budget.add_user('alice', daily=1, per_minute=5))
        bob = budget.authenticate('Bearer ' + budget.add_user('bob', daily=1, per_minute=5))
        self.assertIsNone(budget.take(alice, 100))
        self.assertEqual(budget.take(alice, 101), 'user_limit_reached')
        self.assertIsNone(budget.take(bob, 102))

    def test_global_limit_bounds_all_users(self):
        budget = Budget(':memory:', global_daily=3, global_per_minute=100)
        users = [budget.authenticate('Bearer ' + budget.add_user(f'u{i}')) for i in range(4)]
        self.assertEqual([budget.take(u, 100 + i) for i, u in enumerate(users)],
                         [None, None, None, 'service_limit_reached'])

    def test_tokens_are_random_and_only_their_hash_is_stored(self):
        budget = Budget(':memory:')
        first, second = budget.add_user('alice'), budget.add_user('bob')
        self.assertNotEqual(first, second)
        self.assertGreaterEqual(len(first), 32)
        stored = repr(budget.db.execute('SELECT * FROM users').fetchall())
        self.assertNotIn(first, stored)
        self.assertNotIn(second, stored)

    def test_unknown_disabled_and_rotated_tokens_are_refused(self):
        budget = Budget(':memory:')
        token = budget.add_user('alice')
        for header in ['', 'Bearer', 'Bearer ' + 'x' * 40, token, 'Basic ' + token]:
            self.assertIsNone(budget.authenticate(header))
        budget.set_enabled('alice', False)
        self.assertIsNone(budget.authenticate('Bearer ' + token))
        budget.set_enabled('alice', True)
        new = budget.rotate_token('alice')
        self.assertIsNone(budget.authenticate('Bearer ' + token))
        self.assertIsNotNone(budget.authenticate('Bearer ' + new))

    def test_a_user_disabled_mid_request_is_not_charged(self):
        budget = Budget(':memory:')
        user = budget.authenticate('Bearer ' + budget.add_user('alice'))
        budget.set_enabled('alice', False)
        self.assertEqual(budget.take(user, 100), 'unauthorized')

    def test_legacy_shared_token_works_until_unset(self):
        budget = Budget(':memory:')
        legacy = 'L' * 40
        budget.sync_legacy(legacy)
        self.assertIsNotNone(budget.authenticate('Bearer ' + legacy))
        budget.sync_legacy('')
        self.assertIsNone(budget.authenticate('Bearer ' + legacy))

    def test_existing_shared_token_database_is_migrated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'voice_budget.sqlite')
            old = sqlite3.connect(path)
            with old:
                old.execute('CREATE TABLE calls (at REAL)')
                old.executemany('INSERT INTO calls VALUES (?)', [(100,), (101,)])
            old.close()
            budget = Budget(path, global_daily=3)
            user = budget.authenticate('Bearer ' + budget.add_user('alice'))
            # Calls made before the upgrade still count towards the global cap.
            self.assertIsNone(budget.take(user, 200))
            self.assertEqual(budget.take(user, 201), 'service_limit_reached')
            budget.db.close()

    def test_handler_status_codes(self):
        budget = Budget(':memory:')
        user_token = budget.add_user('alice', daily=1, per_minute=1)

        def call(token):
            handler = object.__new__(Handler)
            handler.headers = {'Authorization': 'Bearer ' + token,
                               'Content-Length': '0'}
            handler.server = MagicMock(budget=budget, audio_enabled=True)
            replies = []
            handler.reply = lambda code, body: replies.append((code, body))
            handler.do_audio()
            return replies

        self.assertEqual(call('x' * 40), [(401, {'error': 'unauthorized'})])
        # Authenticated but malformed: rejected before any budget is spent.
        self.assertEqual(call(user_token), [(400, {'error': 'invalid_audio'})])
        self.assertEqual(budget.users()[0][4], 0)

    def test_admin_commands(self):
        budget = Budget(':memory:')
        lines = []
        manage_users(['add', 'alice', '--daily', '5', '--per-minute', '2'], budget, lines.append)
        token = lines.pop()
        self.assertIsNotNone(budget.authenticate('Bearer ' + token))
        manage_users(['limits', 'alice', '--daily', '9', '--per-minute', '3'], budget, lines.append)
        manage_users(['disable', 'alice'], budget, lines.append)
        manage_users(['list'], budget, lines.append)
        self.assertEqual(lines, ['alice\tdisabled\t0/9 today\t3/min'])
        with self.assertRaises(SystemExit):
            manage_users(['add', 'alice'], budget, lines.append)
        with self.assertRaises(SystemExit):
            manage_users(['rotate', 'nobody'], budget, lines.append)

    def test_concurrent_requests_cannot_overspend(self):
        # The server is threaded: racing requests share one Budget.
        budget = Budget(':memory:', global_daily=1000, global_per_minute=1000)
        user = budget.authenticate('Bearer ' + budget.add_user('alice', daily=50, per_minute=50))
        granted, errors = [], []
        start = threading.Barrier(20, timeout=5)

        def worker():
            start.wait()
            for _ in range(5):
                try:
                    granted.append(budget.take(user, 1000) is None)
                except Exception as error:  # noqa: BLE001 - recorded for the assert
                    errors.append(error)

        # Daemon threads with a deadline: an unsafe Budget can wedge the shared
        # connection, which must fail this test rather than hang the suite.
        threads = [threading.Thread(target=worker, daemon=True) for _ in range(20)]
        for thread in threads:
            thread.start()
        deadline = time.monotonic() + 10
        for thread in threads:
            thread.join(timeout=max(0, deadline - time.monotonic()))
        self.assertFalse(any(thread.is_alive() for thread in threads), 'Budget deadlocked')
        self.assertEqual(errors, [])
        self.assertEqual(granted.count(True), 50)

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

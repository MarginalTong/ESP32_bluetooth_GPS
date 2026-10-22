/// The spoken conversation can use a different language from the phone UI.
/// Gemini returns the transcription alongside each answer, so use that for
/// follow-up questions and confirmations rather than the system locale.
bool voiceTurnIsEnglish(String utterance, {required bool fallbackEnglish}) {
  if (_han.hasMatch(utterance)) return false;
  if (_latin.hasMatch(utterance)) return true;
  return fallbackEnglish;
}

/// Match the synthesis voice to the actual reply. Chinese replies often
/// contain Latin place names, so Han takes precedence over Latin characters.
bool voiceReplyIsEnglish(String reply, {required bool fallbackEnglish}) {
  if (_han.hasMatch(reply)) return false;
  if (_latin.hasMatch(reply)) return true;
  return fallbackEnglish;
}

final _han = RegExp(r'[\u3400-\u9fff]');
final _latin = RegExp(r'[A-Za-z]');

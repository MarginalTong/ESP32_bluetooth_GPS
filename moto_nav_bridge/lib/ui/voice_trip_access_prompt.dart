import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../services/voice_trip_access.dart';

Future<VoiceTripAccessChoice?> showVoiceTripAccessPrompt(BuildContext context) {
  final en = AppText.of(context).isEnglish;
  return showDialog<VoiceTripAccessChoice>(
      context: context,
      builder: (context) => AlertDialog(
            title: Text(
                en ? 'Let Agent use trip information?' : '允许 Agent 使用行程信息？'),
            content: Text(en
                ? 'When you speak, the current route summary and which saved place slots exist may be sent to the voice service. Full saved addresses stay on this phone unless you explicitly ask about one. This lets Agent answer route questions and propose changes. You can change your choice later in Voice assistant.'
                : '对话时，当前路线摘要和已保存地点的类别可能发送给语音服务。完整的已保存地址留在手机上，除非你明确询问。开启后 Agent 才能回答路线问题并提出更改；之后可在语音助手中修改选择。'),
            actions: [
              TextButton(
                  onPressed: () =>
                      Navigator.pop(context, VoiceTripAccessChoice.neverAsk),
                  child: Text(en ? 'Never ask again' : '永不再问')),
              TextButton(
                  onPressed: () =>
                      Navigator.pop(context, VoiceTripAccessChoice.notNow),
                  child: Text(en ? 'Not this trip' : '这次不要')),
              FilledButton(
                  onPressed: () =>
                      Navigator.pop(context, VoiceTripAccessChoice.allow),
                  child: Text(en ? 'Allow trip access' : '允许行程访问')),
            ],
          ));
}

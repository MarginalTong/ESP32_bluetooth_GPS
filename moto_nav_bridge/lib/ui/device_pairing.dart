import 'package:flutter/material.dart';
import '../l10n/app_text.dart';
import '../services/ble_service.dart';

Future<void> connectDisplay(BuildContext context, BleService ble) async {
  final text = AppText.of(context);
  await ble.connect(
    chooseDevice: (devices) async {
      if (!context.mounted) return null;
      return showDialog(
          context: context,
          builder: (dialog) => SimpleDialog(
                title: Text(text.selectDisplay),
                children: [
                  for (final result in devices)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialog, result.device),
                      child: Text(
                          '${result.advertisementData.advName.isNotEmpty ? result.advertisementData.advName : result.device.platformName}\n${result.device.remoteId.str}'),
                    ),
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialog),
                      child: Text(text.cancelAction)),
                ],
              ));
    },
    enterCode: () async {
      if (!context.mounted) return null;
      var code = '';
      return showDialog<String>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(text.verifyDisplay),
                content: TextField(
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    onChanged: (value) => code = value.trim(),
                    decoration: InputDecoration(labelText: text.screenCode)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: Text(text.cancelAction)),
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, code),
                      child: Text(text.confirmAction)),
                ],
              ));
    },
  );
}

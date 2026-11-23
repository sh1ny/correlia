import 'dart:io';

import 'package:correlia_icinga2_notify/correlia_icinga2_notify.dart';

Future<void> main(List<String> args) async {
  final code = await runSender(args);
  await stderr.flush();
  exit(code);
}

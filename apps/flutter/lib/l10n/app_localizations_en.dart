// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get navControl => 'Control';

  @override
  String get navChat => 'Chat';

  @override
  String get navSettings => 'Settings';

  @override
  String get navConnections => 'Connections';

  @override
  String get navAbout => 'About';

  @override
  String get navStage => 'Stage';

  @override
  String get statusGatewayHost => 'Gateway host';

  @override
  String get statusAttempt => 'Attempt';

  @override
  String get connectionHost => 'Host';

  @override
  String get connectionPort => 'Port';

  @override
  String get connectionToken => 'Token';

  @override
  String get connectionConnect => 'Connect';

  @override
  String get connectionDisconnect => 'Disconnect';

  @override
  String get chatInputHint => 'Chat input — deferred';

  @override
  String get sendDeferred => 'Send — deferred';
}

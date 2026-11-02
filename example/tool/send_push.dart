// A minimal server: sends one toast to a channel URI the example app printed.
//
//   WNS_TENANT_ID=<tenant GUID> WNS_CLIENT_ID=<GUID> WNS_CLIENT_SECRET=<secret> \
//     dart run tool/send_push.dart <channel URI> [argument]
//
// The app registration must be multi-tenant; WNS_CLIENT_ID is its Application
// (client) ID, the GUID patch_manifest takes as --app-id, not the remoteId the
// app passes. The secret stays on the server, never in the app.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/send_push.dart <channel URI> [argument]',
    );
    exit(64);
  }
  final channel = Uri.parse(args[0]);
  // WNS only accepts pushes to its own hosts; never send a token elsewhere.
  if (channel.scheme != 'https' ||
      !channel.host.endsWith('.notify.windows.com')) {
    stderr.writeln('Not a WNS channel URI: $channel');
    exit(65);
  }
  final argument = args.length > 1 ? args[1] : 'push:hello';

  final env = Platform.environment;
  final tenant = env['WNS_TENANT_ID'];
  final clientId = env['WNS_CLIENT_ID'];
  final secret = env['WNS_CLIENT_SECRET'];
  if (tenant == null || clientId == null || secret == null) {
    stderr.writeln('Set WNS_TENANT_ID, WNS_CLIENT_ID and WNS_CLIENT_SECRET.');
    exit(64);
  }

  final tokenResponse = await http.post(
    Uri.parse('https://login.microsoftonline.com/$tenant/oauth2/v2.0/token'),
    body: {
      'grant_type': 'client_credentials',
      'client_id': clientId,
      'client_secret': secret,
      'scope': 'https://wns.windows.com/.default',
    },
  );
  if (tokenResponse.statusCode != 200) {
    stderr.writeln('Token request failed: ${tokenResponse.body}');
    exit(1);
  }
  final token =
      (jsonDecode(tokenResponse.body) as Map<String, Object?>)['access_token'];

  final toast =
      '<toast launch="${_xml(argument)}"><visual>'
      '<binding template="ToastGeneric">'
      '<text>Hello from your server</text>'
      '<text>Click to send "${_xml(argument)}" to the app.</text>'
      '</binding></visual></toast>';
  final response = await http.post(
    channel,
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'text/xml',
      'X-WNS-Type': 'wns/toast',
    },
    body: toast,
  );
  switch (response.statusCode) {
    case 200:
      stdout.writeln('Delivered (${response.headers['x-wns-msg-id'] ?? ''}).');
    case 404 || 410:
      // The channel expired or the app was uninstalled: forget it.
      stderr.writeln('Channel is gone (${response.statusCode}).');
      exit(1);
    default:
      stderr.writeln('WNS answered ${response.statusCode}: ${response.body}');
      exit(1);
  }
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

import 'dart:io';

import 'package:emad_bacheca_backend/database.dart';
import 'package:emad_bacheca_backend/server.dart';
import 'package:shelf/shelf_io.dart' as io;

/// Avvia il server.
///
/// Variabili d'ambiente opzionali:
/// - `PORT`: porta di ascolto (default 8080)
/// - `DATA_DIR`: cartella dei dati persistenti (default `data`)
Future<void> main() async {
  final porta = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final cartellaDati = Platform.environment['DATA_DIR'] ?? 'data';

  final db = await Database.apri(cartellaDati);
  final server = await io.serve(
    creaHandler(db),
    InternetAddress.anyIPv4, // raggiungibile anche dallo smartphone in LAN
    porta,
  );

  print('Server avviato sulla porta ${server.port}');
  print('Dati salvati in: ${Directory(cartellaDati).absolute.path}');
  print('Indirizzi raggiungibili:');
  print('  - http://localhost:${server.port}  (questo computer)');
  print('  - http://10.0.2.2:${server.port}  (emulatore Android)');
  for (final interfaccia in await NetworkInterface.list(
      type: InternetAddressType.IPv4)) {
    for (final indirizzo in interfaccia.addresses) {
      print('  - http://${indirizzo.address}:${server.port}  '
          '(${interfaccia.name})');
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:emad_bacheca_backend/database.dart';
import 'package:emad_bacheca_backend/server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late String base;

  Future<void> avvia() async {
    final db = await Database.apri(tmp.path);
    server = await io.serve(creaHandler(db), InternetAddress.loopbackIPv4, 0);
    base = 'http://localhost:${server.port}';
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bacheca_test');
    await avvia();
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  Future<http.Response> post(String path, Object body, {String? token}) =>
      http.post(Uri.parse('$base$path'),
          headers: {
            'content-type': 'application/json',
            if (token != null) 'authorization': 'Bearer $token',
          },
          body: jsonEncode(body));

  Future<http.Response> get(String path, {String? token}) =>
      http.get(Uri.parse('$base$path'),
          headers: {if (token != null) 'authorization': 'Bearer $token'});

  Map<String, dynamic> j(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  final pdf = utf8.encode('%PDF-1.4\n% finto pdf di prova\n%%EOF');

  test('scenari S1, S2, S3 completi e persistenza', () async {
    // S1 – registrazione, login, pubblicazione
    var r = await post('/api/auth/registrazione',
        {'nome': 'Acme', 'email': 'hr@acme.it', 'password': 'segreta1'});
    expect(r.statusCode, 201);

    r = await post('/api/auth/registrazione',
        {'nome': 'Acme', 'email': 'HR@acme.it', 'password': 'segreta1'});
    expect(r.statusCode, 409, reason: 'email duplicata');

    r = await post('/api/auth/login',
        {'email': 'hr@acme.it', 'password': 'sbagliata'});
    expect(r.statusCode, 401);

    r = await post('/api/auth/login',
        {'email': 'hr@acme.it', 'password': 'segreta1'});
    expect(r.statusCode, 200);
    final token = j(r)['token'] as String;

    r = await post('/api/annunci', {'titolo': 'X', 'descrizione': 'Y'});
    expect(r.statusCode, 401, reason: 'pubblicazione senza login');

    r = await post('/api/annunci',
        {'titolo': 'Sviluppatore Flutter', 'descrizione': 'Full time'},
        token: token);
    expect(r.statusCode, 201);
    final annuncioId = j(r)['annuncio']['id'] as String;

    r = await get('/api/annunci');
    expect((j(r)['annunci'] as List).single['aziendaNome'], 'Acme');

    // S2 – candidatura
    final req = http.MultipartRequest(
        'POST', Uri.parse('$base/api/annunci/$annuncioId/candidature'))
      ..fields.addAll(
          {'nome': 'Mario', 'cognome': 'Rossi', 'email': 'mario@rossi.it'})
      ..files.add(http.MultipartFile.fromBytes('cv', pdf,
          filename: 'cv_mario.pdf'));
    r = await http.Response.fromStream(await req.send());
    expect(r.statusCode, 201, reason: r.body);

    final nonPdf = http.MultipartRequest(
        'POST', Uri.parse('$base/api/annunci/$annuncioId/candidature'))
      ..fields.addAll({'nome': 'A', 'cognome': 'B', 'email': 'a@b.it'})
      ..files.add(
          http.MultipartFile.fromBytes('cv', [1, 2, 3, 4, 5], filename: 'x'));
    r = await http.Response.fromStream(await nonPdf.send());
    expect(r.statusCode, 400);

    // Riavvio del server: i dati devono restare
    await server.close(force: true);
    await avvia();

    // S3 – consultazione candidature e logout
    r = await get('/api/me/annunci', token: token);
    expect((j(r)['annunci'] as List).single['numeroCandidature'], 1);

    r = await get('/api/annunci/$annuncioId/candidature', token: token);
    final cand = (j(r)['candidature'] as List).single;
    expect(cand['cognome'], 'Rossi');

    r = await get('/api/candidature/${cand['id']}/cv', token: token);
    expect(r.statusCode, 200);
    expect(r.bodyBytes, pdf);

    r = await get('/api/candidature/${cand['id']}/cv');
    expect(r.statusCode, 401, reason: 'cv senza login');

    r = await post('/api/auth/logout', {}, token: token);
    expect(r.statusCode, 200);
    r = await get('/api/me/annunci', token: token);
    expect(r.statusCode, 401, reason: 'token invalidato dopo il logout');
  });
}

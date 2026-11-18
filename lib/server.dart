import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'database.dart';

/// Dimensione massima accettata per un curriculum (10 MB).
const dimensioneMassimaCv = 10 * 1024 * 1024;

final _regexEmail = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Costruisce l'handler HTTP con tutte le API della bacheca.
Handler creaHandler(Database db) {
  final api = _Api(db);
  final router = Router()
    ..get('/', api.home)
    // Autenticazione aziende
    ..post('/api/auth/registrazione', api.registrazione)
    ..post('/api/auth/login', api.login)
    ..post('/api/auth/logout', api.logout)
    ..get('/api/auth/me', api.me)
    // Bacheca pubblica
    ..get('/api/annunci', api.elencoAnnunci)
    ..get('/api/annunci/<id>', api.dettaglioAnnuncio)
    ..post('/api/annunci/<id>/candidature', api.inviaCandidatura)
    // Area riservata azienda
    ..post('/api/annunci', api.pubblicaAnnuncio)
    ..get('/api/me/annunci', api.mieiAnnunci)
    ..get('/api/annunci/<id>/candidature', api.candidatureAnnuncio)
    ..get('/api/candidature/<id>', api.dettaglioCandidatura)
    ..get('/api/candidature/<id>/cv', api.scaricaCv);

  return const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_gestioneErrori())
      .addHandler(router.call);
}

class _Api {
  _Api(this.db);
  final Database db;

  Response home(Request _) => _json(200, {
        'servizio': 'Bacheca annunci di lavoro – EMAD',
        'stato': 'in esecuzione',
      });

  // ------------------------------------------------------- Autenticazione

  Future<Response> registrazione(Request req) async {
    final body = await _leggiJson(req);
    final nome = _testo(body['nome']);
    final email = _testo(body['email']).toLowerCase();
    final password = body['password']?.toString() ?? '';

    final errori = <String, String>{};
    if (nome.isEmpty) errori['nome'] = 'Il nome dell\'azienda è obbligatorio';
    if (!_regexEmail.hasMatch(email)) errori['email'] = 'Email non valida';
    if (password.length < 6) {
      errori['password'] = 'La password deve avere almeno 6 caratteri';
    }
    if (errori.isNotEmpty) return _erroreValidazione(errori);

    if (db.aziendaPerEmail(email) != null) {
      return _errore(409, 'Esiste già un account con questa email');
    }
    final azienda =
        db.creaAzienda(nome: nome, email: email, password: password);
    return _json(201, {'azienda': Database.aziendaPubblica(azienda)});
  }

  Future<Response> login(Request req) async {
    final body = await _leggiJson(req);
    final email = _testo(body['email']);
    final password = body['password']?.toString() ?? '';
    final azienda = db.aziendaPerEmail(email);
    if (azienda == null || !db.verificaPassword(azienda, password)) {
      return _errore(401, 'Email o password non corretti');
    }
    final token = db.creaSessione(azienda['id'] as String);
    return _json(200, {
      'token': token,
      'azienda': Database.aziendaPubblica(azienda),
    });
  }

  Response logout(Request req) {
    final token = _token(req);
    if (token != null) db.eliminaSessione(token);
    return _json(200, {'messaggio': 'Logout effettuato'});
  }

  Response me(Request req) {
    final azienda = _autentica(req);
    if (azienda == null) return _nonAutenticato();
    return _json(200, {'azienda': Database.aziendaPubblica(azienda)});
  }

  // ------------------------------------------------------------- Annunci

  Response elencoAnnunci(Request _) =>
      _json(200, {'annunci': db.elencoAnnunci()});

  Response dettaglioAnnuncio(Request _, String id) {
    final annuncio = db.annuncioPerId(id);
    if (annuncio == null) return _errore(404, 'Annuncio non trovato');
    return _json(200, {'annuncio': db.annuncioCompleto(annuncio)});
  }

  Future<Response> pubblicaAnnuncio(Request req) async {
    final azienda = _autentica(req);
    if (azienda == null) return _nonAutenticato();

    final body = await _leggiJson(req);
    final titolo = _testo(body['titolo']);
    final descrizione = _testo(body['descrizione']);
    final errori = <String, String>{};
    if (titolo.isEmpty) errori['titolo'] = 'Il titolo è obbligatorio';
    if (descrizione.isEmpty) {
      errori['descrizione'] = 'La descrizione è obbligatoria';
    }
    if (errori.isNotEmpty) return _erroreValidazione(errori);

    final annuncio = db.creaAnnuncio(
      aziendaId: azienda['id'] as String,
      titolo: titolo,
      descrizione: descrizione,
      luogo: body['luogo']?.toString(),
      tipoContratto: body['tipoContratto']?.toString(),
    );
    return _json(201, {'annuncio': db.annuncioCompleto(annuncio)});
  }

  Response mieiAnnunci(Request req) {
    final azienda = _autentica(req);
    if (azienda == null) return _nonAutenticato();
    return _json(200, {
      'annunci': db.elencoAnnunci(aziendaId: azienda['id'] as String),
    });
  }

  // ---------------------------------------------------------- Candidature

  Future<Response> inviaCandidatura(Request req, String id) async {
    final annuncio = db.annuncioPerId(id);
    if (annuncio == null) return _errore(404, 'Annuncio non trovato');

    final tipo = req.headers['content-type'];
    final mediaType = tipo == null ? null : MediaType.parse(tipo);
    final boundary = mediaType?.parameters['boundary'];
    if (mediaType?.mimeType != 'multipart/form-data' || boundary == null) {
      return _errore(400, 'La richiesta deve essere multipart/form-data');
    }

    final campi = <String, String>{};
    String? nomeFile;
    Uint8List? cv;

    await for (final parte
        in MimeMultipartTransformer(boundary).bind(req.read())) {
      final disposizione =
          HeaderValue.parse(parte.headers['content-disposition'] ?? '');
      final nomeCampo = disposizione.parameters['name'];
      final builder = BytesBuilder(copy: false);
      await for (final blocco in parte) {
        builder.add(blocco);
        if (builder.length > dimensioneMassimaCv) {
          return _errore(413, 'Il curriculum supera la dimensione massima '
              'di 10 MB');
        }
      }
      if (nomeCampo == 'cv') {
        nomeFile = disposizione.parameters['filename'] ?? 'curriculum.pdf';
        cv = builder.takeBytes();
      } else if (nomeCampo != null) {
        campi[nomeCampo] = utf8.decode(builder.takeBytes());
      }
    }

    final nome = _testo(campi['nome']);
    final cognome = _testo(campi['cognome']);
    final email = _testo(campi['email']);
    final errori = <String, String>{};
    if (nome.isEmpty) errori['nome'] = 'Il nome è obbligatorio';
    if (cognome.isEmpty) errori['cognome'] = 'Il cognome è obbligatorio';
    if (!_regexEmail.hasMatch(email)) errori['email'] = 'Email non valida';
    if (cv == null || cv.isEmpty) {
      errori['cv'] = 'Il curriculum è obbligatorio';
    } else if (!_isPdf(cv)) {
      errori['cv'] = 'Il curriculum deve essere un file PDF';
    }
    if (errori.isNotEmpty) return _erroreValidazione(errori);

    final candidatura = await db.creaCandidatura(
      annuncioId: id,
      nome: nome,
      cognome: cognome,
      email: email,
      telefono: campi['telefono'],
      messaggio: campi['messaggio'],
      nomeFileCv: nomeFile!,
      contenutoCv: cv!,
    );
    return _json(201, {'candidatura': candidatura});
  }

  Response candidatureAnnuncio(Request req, String id) {
    final azienda = _autentica(req);
    if (azienda == null) return _nonAutenticato();
    final annuncio = db.annuncioPerId(id);
    if (annuncio == null) return _errore(404, 'Annuncio non trovato');
    if (annuncio['aziendaId'] != azienda['id']) {
      return _errore(403, 'Questo annuncio non appartiene alla tua azienda');
    }
    return _json(200, {
      'annuncio': db.annuncioCompleto(annuncio),
      'candidature': db.candidaturePerAnnuncio(id),
    });
  }

  Response dettaglioCandidatura(Request req, String id) {
    final (candidatura, errore) = _candidaturaDellAzienda(req, id);
    if (errore != null) return errore;
    return _json(200, {'candidatura': candidatura});
  }

  Future<Response> scaricaCv(Request req, String id) async {
    final (candidatura, errore) = _candidaturaDellAzienda(req, id);
    if (errore != null) return errore;
    final file = db.fileCv(id);
    if (!await file.exists()) return _errore(404, 'Curriculum non trovato');
    final nome = (candidatura!['nomeFileCv'] as String)
        .replaceAll(RegExp(r'[^\w.\- ]'), '_');
    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': 'application/pdf',
        'content-length': '${await file.length()}',
        'content-disposition': 'inline; filename="$nome"',
      },
    );
  }

  // -------------------------------------------------------------- Utilità

  /// Restituisce la candidatura solo se appartiene a un annuncio
  /// dell'azienda autenticata.
  (Map<String, dynamic>?, Response?) _candidaturaDellAzienda(
      Request req, String id) {
    final azienda = _autentica(req);
    if (azienda == null) return (null, _nonAutenticato());
    final candidatura = db.candidaturaPerId(id);
    if (candidatura == null) {
      return (null, _errore(404, 'Candidatura non trovata'));
    }
    final annuncio = db.annuncioPerId(candidatura['annuncioId'] as String);
    if (annuncio?['aziendaId'] != azienda['id']) {
      return (null, _errore(403, 'Non puoi vedere questa candidatura'));
    }
    return (candidatura, null);
  }

  String? _token(Request req) {
    final h = req.headers['authorization'];
    if (h == null || !h.startsWith('Bearer ')) return null;
    return h.substring(7).trim();
  }

  Map<String, dynamic>? _autentica(Request req) {
    final token = _token(req);
    if (token == null) return null;
    final id = db.aziendaDaToken(token);
    return id == null ? null : db.aziendaPerId(id);
  }

  static bool _isPdf(List<int> b) =>
      b.length > 4 &&
      b[0] == 0x25 && // %
      b[1] == 0x50 && // P
      b[2] == 0x44 && // D
      b[3] == 0x46; //   F
}

// ------------------------------------------------------------ Risposte JSON

String _testo(Object? v) => v?.toString().trim() ?? '';

Future<Map<String, dynamic>> _leggiJson(Request req) async {
  final testo = await req.readAsString();
  if (testo.isEmpty) return {};
  try {
    final dati = jsonDecode(testo);
    if (dati is Map<String, dynamic>) return dati;
  } on FormatException {
    // gestito sotto
  }
  throw const _RichiestaNonValida('Corpo della richiesta non valido');
}

Response _json(int stato, Object dati) => Response(
      stato,
      body: jsonEncode(dati),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Response _errore(int stato, String messaggio) =>
    _json(stato, {'errore': messaggio});

Response _erroreValidazione(Map<String, String> campi) => _json(400, {
      'errore': campi.values.first,
      'campi': campi,
    });

Response _nonAutenticato() =>
    _errore(401, 'Accesso riservato: effettua il login');

class _RichiestaNonValida implements Exception {
  const _RichiestaNonValida(this.messaggio);
  final String messaggio;
}

Middleware _gestioneErrori() => (inner) => (req) async {
      try {
        return await inner(req);
      } on _RichiestaNonValida catch (e) {
        return _errore(400, e.messaggio);
      } on MimeMultipartException {
        return _errore(400, 'Dati del form non validi');
      } catch (e, st) {
        stderr.writeln('Errore interno: $e\n$st');
        return _errore(500, 'Errore interno del server');
      }
    };

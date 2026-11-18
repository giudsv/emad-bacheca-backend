import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Archivio persistente su file JSON.
///
/// Tutti i dati (aziende, annunci, candidature, sessioni) sono tenuti in
/// memoria e riscritti su `db.json` a ogni modifica, quindi restano
/// disponibili anche dopo il riavvio del server. I curriculum sono salvati
/// come file separati nella cartella `cv/`.
class Database {
  Database._(this.cartellaDati, this._dati);

  final String cartellaDati;
  final Map<String, dynamic> _dati;

  String get _fileDb => p.join(cartellaDati, 'db.json');
  String get cartellaCv => p.join(cartellaDati, 'cv');

  static Future<Database> apri(String cartellaDati) async {
    await Directory(p.join(cartellaDati, 'cv')).create(recursive: true);
    final file = File(p.join(cartellaDati, 'db.json'));
    Map<String, dynamic> dati;
    if (await file.exists()) {
      dati = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } else {
      dati = {};
    }
    for (final chiave in ['aziende', 'annunci', 'candidature']) {
      dati.putIfAbsent(chiave, () => <dynamic>[]);
    }
    dati.putIfAbsent('sessioni', () => <String, dynamic>{});
    return Database._(cartellaDati, dati);
  }

  List<Map<String, dynamic>> _lista(String nome) =>
      (_dati[nome] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> get _sessioni =>
      _dati['sessioni'] as Map<String, dynamic>;

  /// Scrittura atomica: prima su un file temporaneo, poi rinomina.
  void _salva() {
    final tmp = File('$_fileDb.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(_dati),
      flush: true,
    );
    tmp.renameSync(_fileDb);
  }

  // ---------------------------------------------------------------- Aziende

  Map<String, dynamic>? aziendaPerEmail(String email) {
    final e = email.trim().toLowerCase();
    for (final a in _lista('aziende')) {
      if (a['email'] == e) return a;
    }
    return null;
  }

  Map<String, dynamic>? aziendaPerId(String id) {
    for (final a in _lista('aziende')) {
      if (a['id'] == id) return a;
    }
    return null;
  }

  Map<String, dynamic> creaAzienda({
    required String nome,
    required String email,
    required String password,
  }) {
    final sale = _casuale(16);
    final azienda = {
      'id': _uuid.v4(),
      'nome': nome.trim(),
      'email': email.trim().toLowerCase(),
      'sale': sale,
      'hashPassword': _hash(password, sale),
      'dataRegistrazione': DateTime.now().toUtc().toIso8601String(),
    };
    _lista('aziende').add(azienda);
    _salva();
    return azienda;
  }

  bool verificaPassword(Map<String, dynamic> azienda, String password) =>
      _hash(password, azienda['sale'] as String) == azienda['hashPassword'];

  static Map<String, dynamic> aziendaPubblica(Map<String, dynamic> a) => {
        'id': a['id'],
        'nome': a['nome'],
        'email': a['email'],
      };

  // --------------------------------------------------------------- Sessioni

  String creaSessione(String aziendaId) {
    final token = _casuale(32);
    _sessioni[token] = aziendaId;
    _salva();
    return token;
  }

  String? aziendaDaToken(String token) => _sessioni[token] as String?;

  void eliminaSessione(String token) {
    if (_sessioni.remove(token) != null) _salva();
  }

  // ---------------------------------------------------------------- Annunci

  Map<String, dynamic> creaAnnuncio({
    required String aziendaId,
    required String titolo,
    required String descrizione,
    String? luogo,
    String? tipoContratto,
  }) {
    final annuncio = {
      'id': _uuid.v4(),
      'aziendaId': aziendaId,
      'titolo': titolo.trim(),
      'descrizione': descrizione.trim(),
      'luogo': _opzionale(luogo),
      'tipoContratto': _opzionale(tipoContratto),
      'dataPubblicazione': DateTime.now().toUtc().toIso8601String(),
    };
    _lista('annunci').add(annuncio);
    _salva();
    return annuncio;
  }

  Map<String, dynamic>? annuncioPerId(String id) {
    for (final a in _lista('annunci')) {
      if (a['id'] == id) return a;
    }
    return null;
  }

  /// Annuncio arricchito con il nome dell'azienda e il numero di candidature.
  Map<String, dynamic> annuncioCompleto(Map<String, dynamic> annuncio) => {
        ...annuncio,
        'aziendaNome': aziendaPerId(annuncio['aziendaId'] as String)?['nome'],
        'numeroCandidature': _lista('candidature')
            .where((c) => c['annuncioId'] == annuncio['id'])
            .length,
      };

  /// Tutti gli annunci, dal più recente.
  List<Map<String, dynamic>> elencoAnnunci({String? aziendaId}) {
    final risultato = _lista('annunci')
        .where((a) => aziendaId == null || a['aziendaId'] == aziendaId)
        .map(annuncioCompleto)
        .toList()
      ..sort((a, b) => (b['dataPubblicazione'] as String)
          .compareTo(a['dataPubblicazione'] as String));
    return risultato;
  }

  // ------------------------------------------------------------ Candidature

  Future<Map<String, dynamic>> creaCandidatura({
    required String annuncioId,
    required String nome,
    required String cognome,
    required String email,
    String? telefono,
    String? messaggio,
    required String nomeFileCv,
    required List<int> contenutoCv,
  }) async {
    final id = _uuid.v4();
    await File(p.join(cartellaCv, '$id.pdf')).writeAsBytes(contenutoCv);
    final candidatura = {
      'id': id,
      'annuncioId': annuncioId,
      'nome': nome.trim(),
      'cognome': cognome.trim(),
      'email': email.trim().toLowerCase(),
      'telefono': _opzionale(telefono),
      'messaggio': _opzionale(messaggio),
      'nomeFileCv': nomeFileCv,
      'dimensioneCv': contenutoCv.length,
      'dataInvio': DateTime.now().toUtc().toIso8601String(),
    };
    _lista('candidature').add(candidatura);
    _salva();
    return candidatura;
  }

  Map<String, dynamic>? candidaturaPerId(String id) {
    for (final c in _lista('candidature')) {
      if (c['id'] == id) return c;
    }
    return null;
  }

  List<Map<String, dynamic>> candidaturePerAnnuncio(String annuncioId) =>
      _lista('candidature')
          .where((c) => c['annuncioId'] == annuncioId)
          .toList()
        ..sort((a, b) =>
            (b['dataInvio'] as String).compareTo(a['dataInvio'] as String));

  File fileCv(String candidaturaId) =>
      File(p.join(cartellaCv, '$candidaturaId.pdf'));

  // ------------------------------------------------------------- Utilità

  static String? _opzionale(String? valore) {
    final v = valore?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  static String _casuale(int byte) {
    final r = Random.secure();
    return List.generate(byte, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Hash della password con sale e iterazioni ripetute di SHA-256.
  static String _hash(String password, String sale) {
    List<int> digest = utf8.encode('$sale:$password');
    for (var i = 0; i < 10000; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

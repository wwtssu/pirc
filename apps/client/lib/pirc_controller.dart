import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/rust/api/client.dart' as bridge;
import 'connection_store.dart';

Map<String, dynamic> decodeView(String encoded) =>
    jsonDecode(encoded) as Map<String, dynamic>;
Future<Map<String, dynamic>> decodeIncomingView(String encoded) async =>
    encoded.length > 65536 ? compute(decodeView, encoded) : decodeView(encoded);

String connectionLabel(String state) => switch (state) {
  'connected' => 'Connected to device',
  'connecting' => 'Connecting',
  'syncing' => 'Syncing',
  'reconnecting' => 'Reconnecting',
  'pairing' => 'Awaiting server approval',
  'blocked' => 'Connection rejected',
  _ => 'No device connected',
};

class SessionView {
  SessionView(Map<String, dynamic> json)
    : snapshot = json['snapshot'] as Map<String, dynamic>,
      ready = json['ready'] as bool,
      lastSeq = json['last_seq'] as int? ?? 0,
      items = (json['items'] as List).cast<Map<String, dynamic>>(),
      gaps = (json['gaps'] as List).cast<String>(),
      history = (json['history'] as Map<String, dynamic>?) ?? {};
  final Map<String, dynamic> snapshot;
  final bool ready;
  final int lastSeq;
  final List<Map<String, dynamic>> items;
  final List<String> gaps;
  final Map<String, dynamic> history;
  bool get paged => history['enabled'] == true;
  bool get historyInitialized => !paged || history['initialized'] == true;
  String? get historyLoading => history['loading'] as String?;
  String? get historyError => history['error'] as String?;
  bool get hasBefore => history['has_before'] == true;
  bool get hasAfter => history['has_after'] == true;
  int get historyRevision => history['revision'] as int? ?? 0;
  int? get historyAnchor => history['anchor'] as int?;
  String get instance => snapshot['instance_id'] as String;
  String get session => snapshot['session_id'] as String;
  String get cwd => snapshot['cwd'] as String;
  String? get sessionName {
    final value = (snapshot['name'] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String get name => sessionName ?? 'Unnamed session';
  Map<String, dynamic>? get controls =>
      (snapshot['controls'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get currentModel =>
      (controls?['model'] as Map?)?.cast<String, dynamic>();
  String? get thinkingLevel => controls?['thinking_level'] as String?;
  bool supportsBuiltin(String command) =>
      ((snapshot['slash_commands'] as List?) ?? []).any(
        (c) => c['name'] == command && c['source'] == 'builtin',
      );
  bool get serverLaunched =>
      (snapshot['launch_id'] as String?)?.isNotEmpty == true;
  bool get supportsExit => serverLaunched && snapshot['can_close'] == true;
  String get state => snapshot['state'] as String;
  bool get attention => snapshot['needs_local_attention'] as bool;
}

class SavedSession {
  SavedSession(Map<String, dynamic> json)
    : id = json['session_id'] as String,
      cwd = json['cwd'] as String,
      name = (json['name'] as String?)?.trim(),
      modified = DateTime.fromMillisecondsSinceEpoch(
        json['modified_ms'] as int,
      );
  final String id;
  final String cwd;
  final String? name;
  final DateTime modified;
  String get title => name == null || name!.isEmpty ? 'Unnamed session' : name!;
}

class SavedSessionCatalog {
  SavedSessionCatalog({required this.sessions, required this.defaultCwd});
  final List<SavedSession> sessions;
  final String defaultCwd;
}

class RemoteDirectoryEntry {
  RemoteDirectoryEntry(Map<String, dynamic> json)
    : name = json['name'] as String,
      path = json['path'] as String,
      isDirectory = json['is_directory'] as bool;
  final String name;
  final String path;
  final bool isDirectory;
}

class RemoteDirectoryPage {
  RemoteDirectoryPage(Map<String, dynamic> json)
    : path = json['path'] as String,
      parent = json['parent'] as String?,
      home = json['home'] as String,
      entries = (json['entries'] as List)
          .map((d) => RemoteDirectoryEntry((d as Map).cast<String, dynamic>()))
          .toList(),
      nextCursor = json['next_cursor'] as String?;
  final String path;
  final String? parent;
  final String home;
  final List<RemoteDirectoryEntry> entries;
  final String? nextCursor;
}

class PircController extends ChangeNotifier {
  PircController({this.preferences});
  final SharedPreferences? preferences;
  String computerId = createComputerId();
  List<String> addresses = [];
  String? serverId;
  String? serverKey;
  Map<String, dynamic>? pairing;
  List<String> otherServerIds = [];
  String? currentAddress;
  int attemptIndex = 0;

  bool startupLoading = false;

  bridge.PircClient? _client;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  String endpoint = 'http://127.0.0.1:43123';
  String connection = 'disconnected';
  String get connectionDescription =>
      connection == 'reconnecting' && attemptIndex > 0
      ? 'Trying another address'
      : connectionLabel(connection);
  String? error;
  String? selectedInstance;
  List<SessionView> sessions = [];
  List<SessionView> get onlineSessions =>
      sessions.where((s) => s.state != 'offline').toList();
  List<Map<String, dynamic>> commands = [];
  final Map<String, String> _drafts = {};
  final Set<String> _cleared = {};
  final Set<String> _dirty = {};
  final Map<String, (String, int?)> _historyRequests = {};
  Timer? _save;
  int _epoch = 0;
  SessionView? get selected =>
      sessions.where((s) => s.instance == selectedInstance).firstOrNull;
  Future<RemoteDirectoryPage> browseDirectories({
    String? path,
    String? cursor,
    bool showHidden = false,
  }) async {
    final client = _client;
    if (client == null || connection != 'connected') {
      throw StateError('Connect to a device first');
    }
    final epoch = _epoch;
    final data = jsonDecode(
      await bridge.browseDirectories(
        client: client,
        path: path,
        cursor: cursor,
        showHidden: showHidden,
      ),
    ) as Map<String, dynamic>;
    if (epoch != _epoch || client != _client || connection != 'connected') {
      throw StateError('The device connection changed. Try again.');
    }
    if (data['type'] != 'directory_list') {
      throw StateError('Update the device server to browse directories.');
    }
    return RemoteDirectoryPage(data);
  }

  Future<SavedSessionCatalog> loadSavedSessions() async {
    final client = _client;
    if (client == null || connection != 'connected') {
      throw StateError('Connect to a device first');
    }
    final data = jsonDecode(
      await bridge.savedSessions(client: client),
    ) as Map<String, dynamic>;
    return SavedSessionCatalog(
      sessions: (data['sessions'] as List)
          .map((s) => SavedSession((s as Map).cast<String, dynamic>()))
          .toList(),
      defaultCwd: data['default_cwd'] as String,
    );
  }

  Future<String> createDirectory(String parent, String name) async {
    final client = _client;
    if (client == null || connection != 'connected') {
      throw StateError('Connect to a device first');
    }
    final epoch = _epoch;
    final data = jsonDecode(
      await bridge.createDirectory(client: client, parent: parent, name: name),
    ) as Map<String, dynamic>;
    if (epoch != _epoch || client != _client || connection != 'connected') {
      throw StateError(
        'The device connection changed. Creation is unconfirmed. Refresh the directory before retrying.',
      );
    }
    if (data['type'] != 'directory_created') {
      throw StateError(
        'Creation is unconfirmed. Refresh the directory to check.',
      );
    }
    return data['path'] as String;
  }

  Future<String> launchSession(
    String cwd, {
    String? sessionId,
    String? name,
  }) async {
    final client = _client;
    if (client == null || connection != 'connected') {
      throw StateError('Connect to a device first');
    }
    final epoch = _epoch;
    final elapsed = Stopwatch()..start();
    final result = jsonDecode(
      await bridge
          .launchSession(
            client: client,
            cwd: cwd,
            sessionId: sessionId,
            name: name,
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw StateError(
              'The device did not confirm the request in time. The terminal may already be open. Check the device and refresh the session list before retrying.',
            ),
          ),
    ) as Map<String, dynamic>;
    final ready = Completer<String>();
    void check() {
      if (ready.isCompleted) return;
      if (epoch != _epoch || client != _client || connection != 'connected') {
        ready.completeError(
          StateError(
            'The device connection was lost. Reconnect and refresh the session list to check whether it was restored.',
          ),
        );
        return;
      }
      final session = onlineSessions
          .where(
            (s) =>
                (result['instance_id'] != null &&
                    s.instance == result['instance_id']) ||
                s.snapshot['launch_id'] == result['launch_id'],
          )
          .firstOrNull;
      if (session != null) {
        if (selectedInstance != session.instance) select(session.instance);
        if (session.ready && !session.attention && !ready.isCompleted) {
          ready.complete(session.instance);
        }
      }
    }

    addListener(check);
    check();
    try {
      return await ready.future.timeout(
        Duration(
          milliseconds: (45000 - elapsed.elapsedMilliseconds).clamp(1, 45000),
        ),
        onTimeout: () => throw StateError(
          'Timed out waiting for the session. Check the agent and connection on the device, then refresh the session list.',
        ),
      );
    } finally {
      removeListener(check);
    }
  }

  String _key(SessionView s) => 'draft:$computerId:${s.session}';
  String draft(SessionView s) =>
      _drafts.putIfAbsent(_key(s), () => preferences?.getString(_key(s)) ?? '');
  void setDraft(SessionView s, String text) {
    _drafts[_key(s)] = text;
    _dirty.add(_key(s));
    _save?.cancel();
    _save = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(flushDrafts()),
    );
    notifyListeners();
  }

  Future<void> flushDrafts() async {
    final keys = Set<String>.of(_dirty);
    _dirty.removeAll(keys);
    for (final key in keys) {
      await preferences?.setString(key, _drafts[key]!);
    }
  }

  void select(String instance) {
    selectedInstance = instance;
    _historyRequests[instance] = ('latest', null);
    if (selected?.paged == true) {
      selected!.history['loading'] = 'latest';
      selected!.history['error'] = null;
    }
    if (_client != null) {
      unawaited(
        bridge.selectSessionView(client: _client!, instanceId: instance),
      );
    }
    notifyListeners();
  }

  Future<void> loadHistory(String direction, {int? cursor}) async {
    final session = selected;
    if (session == null || !session.paged || _client == null) return;
    if (session.historyLoading != null && direction != 'latest') return;
    cursor ??= switch (direction) {
      'before' => session.items.firstOrNull?['first_seq'] as int?,
      'after' => session.items.lastOrNull?['first_seq'] as int?,
      _ => null,
    };
    _historyRequests[session.instance] = (direction, cursor);
    session.history['loading'] = direction;
    session.history['error'] = null;
    notifyListeners();
    try {
      await bridge.loadHistory(
        client: _client!,
        instanceId: session.instance,
        direction: direction,
        cursor: cursor == null ? null : BigInt.from(cursor),
      );
    } catch (_) {
      final current = sessions
          .where((s) => s.instance == session.instance)
          .firstOrNull;
      if (current != null) {
        current.history['loading'] = null;
        current.history['error'] = 'Unable to load messages. Try again.';
        notifyListeners();
      }
    }
  }

  Future<void> retryHistory() async {
    final request = _historyRequests[selectedInstance] ?? ('latest', null);
    await loadHistory(request.$1, cursor: request.$2);
  }

  bool pending(SessionView s) => commands.any(
    (c) =>
        c['instance_id'] == s.instance &&
        (c['status'] == 'pending' ||
            c['status'] == 'unknown' ||
            (c['kind'] != 'prompt' && c['status'] == 'accepted')),
  );
  String? exitDisabledReason(SessionView session) {
    final current = sessions
        .where((s) => s.instance == session.instance)
        .firstOrNull;
    if (current == null || current.state == 'offline') {
      return 'Session is offline';
    }
    if (!current.serverLaunched) {
      return 'This session was started on the device. Exit it on the device.';
    }
    if (!current.supportsExit) {
      return 'Remote exit is unavailable for this session. Exit it on the device.';
    }
    if (connection != 'connected' || !current.ready) {
      return 'Wait for the connection and session to sync, then retry.';
    }
    if (current.attention) return 'This session needs attention on the device';
    if (pending(current)) {
      return 'The previous operation is unconfirmed. Check the device first.';
    }
    if (current.state != 'idle') {
      return 'A task is running. Stop it before exiting.';
    }
    return null;
  }

  Future<void> exitSession(SessionView session) async {
    final reason = exitDisabledReason(session);
    final client = _client;
    if (reason != null || client == null) {
      throw StateError(reason ?? 'Connect to a device first');
    }
    await flushDrafts();
    final id = await bridge.closeSession(
      client: client,
      instanceId: session.instance,
    );
    await _waitForCommand(id);
  }

  bool canSend(SessionView s) => canConfigure(s) && draft(s).trim().isNotEmpty;
  bool canConfigure(SessionView s) =>
      connection == 'connected' &&
      s.ready &&
      s.state == 'idle' &&
      !s.attention &&
      !pending(s);
  bool canStop(SessionView s) =>
      connection == 'connected' &&
      s.ready &&
      (s.state == 'running' || s.state == 'stopping') &&
      !pending(s);
  Future<void> connect(String url, {bool pairAgain = false}) async {
    await disconnect();
    final epoch = ++_epoch;
    endpoint = computerAddress(url);
    connection = 'connecting';
    error = null;
    sessions = [];
    commands = [];
    selectedInstance = null;
    _cleared.clear();
    notifyListeners();
    try {
      final secret = await ConnectionStore.localKey();
      if (epoch != _epoch) return;
      final client = await bridge.createComputerClient(
        addresses: addresses.isEmpty ? [endpoint] : addresses,
        serverId: pairAgain ? null : serverId,
        otherServerIds: otherServerIds,
        secret: secret,
        serverKey: pairAgain ? null : serverKey,
      );
      if (epoch != _epoch) {
        await bridge.closeClient(client: client);
        return;
      }
      _client = client;
      _subscription = bridge
          .watchClient(client: client)
          .asyncMap(decodeIncomingView)
          .listen(
            (view) {
              if (epoch == _epoch) applyDecodedView(view);
            },
            onError: (Object failure) {
              error = '$failure';
              connection = 'disconnected';
              pairing = null;
              notifyListeners();
            },
          );
    } catch (failure) {
      error = '$failure';
      connection = 'disconnected';
      pairing = null;
      notifyListeners();
    }
  }

  void applyView(String encoded) {
    applyDecodedView(decodeView(encoded));
  }

  void applyDecodedView(Map<String, dynamic> view) {
    serverId = view['server_id'] as String? ?? serverId;
    serverKey = view['server_key'] as String? ?? serverKey;
    pairing = (view['pairing'] as Map?)?.cast<String, dynamic>();
    final reportedAddress = view['current_address'] as String?;
    currentAddress = reportedAddress == null
        ? null
        : computerAddress(reportedAddress);
    attemptIndex = view['attempt_index'] as int? ?? 0;
    connection = view['connection'] as String;
    error = view['error'] as String?;
    sessions = (view['sessions'] as List)
        .map((s) => SessionView(s as Map<String, dynamic>))
        .toList();
    commands = (view['commands'] as List).cast<Map<String, dynamic>>();
    for (final c in commands) {
      if (((c['kind'] == 'prompt' && c['status'] == 'accepted') ||
              (!['stop', 'close'].contains(c['kind']) &&
                  c['status'] == 'completed')) &&
          _cleared.add(c['request_id'] as String)) {
        final session = sessions
            .where((s) => s.instance == c['instance_id'])
            .firstOrNull;
        if (session != null && draft(session) == c['text']) {
          _drafts[_key(session)] = '';
          _dirty.add(_key(session));
          unawaited(flushDrafts());
        }
      }
    }
    if (!sessions.any((s) => s.instance == selectedInstance)) {
      selectedInstance = onlineSessions.firstOrNull?.instance;
      if (_client != null && selectedInstance != null) {
        unawaited(
          bridge.selectSessionView(
            client: _client!,
            instanceId: selectedInstance!,
          ),
        );
      }
    }
    notifyListeners();
  }

  Future<void> send() async {
    final s = selected;
    final client = _client;
    if (s == null || client == null || !canSend(s)) return;
    try {
      await bridge.sendPrompt(
        client: client,
        instanceId: s.instance,
        text: draft(s),
      );
    } catch (failure) {
      error = '$failure';
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> runBuiltin(
    SessionView session,
    String command, [
    String args = '',
  ]) async {
    final client = _client;
    final current = sessions
        .where((s) => s.instance == session.instance)
        .firstOrNull;
    if (client == null ||
        current == null ||
        connection != 'connected' ||
        !current.ready ||
        current.state != 'idle' ||
        current.attention ||
        pending(current)) {
      throw StateError(
        'Wait for the session to become idle and the connection to be confirmed.',
      );
    }
    final id = await bridge.sendPrompt(
      client: client,
      instanceId: current.instance,
      text: '/$command${args.isEmpty ? '' : ' $args'}',
    );
    return _waitForCommand(id);
  }

  Future<Map<String, dynamic>> _waitForCommand(String id) async {
    final result = Completer<Map<String, dynamic>>();
    void check() {
      final operation = commands
          .where((c) => c['request_id'] == id)
          .firstOrNull;
      if (operation == null || result.isCompleted) return;
      if (operation['status'] == 'completed') {
        result.complete(
          (operation['data'] as Map?)?.cast<String, dynamic>() ?? {},
        );
      } else if (operation['status'] == 'rejected' ||
          operation['status'] == 'unknown') {
        result.completeError(
          StateError(
            operation['detail'] as String? ??
                'Operation incomplete. Check the session notice.',
          ),
        );
      }
    }

    addListener(check);
    check();
    try {
      return await result.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw StateError(
          'Operation result unconfirmed. Check the session notice.',
        ),
      );
    } finally {
      removeListener(check);
    }
  }

  Future<void> stop() async {
    final s = selected;
    final client = _client;
    if (s == null || client == null || !canStop(s)) return;
    try {
      await bridge.stopSession(client: client, instanceId: s.instance);
    } catch (failure) {
      error = '$failure';
      notifyListeners();
    }
  }

  Future<void> updateAddresses() async {
    if (_client != null) {
      await bridge.setComputerAddresses(client: _client!, addresses: addresses);
    }
  }

  Future<void> reconnect() async {
    if (_client != null) {
      connection = 'syncing';
      error = null;
      notifyListeners();
      await bridge.reconnectClient(client: _client!);
    }
  }

  Future<void> confirmUnknown(String id) async {
    if (_client != null) {
      await bridge.confirmUnknown(client: _client!, requestId: id);
    }
  }

  Future<void> disconnect() async {
    ++_epoch;
    final client = _client;
    _client = null;
    // Close Rust first: cancellation waits for its streaming function to return.
    if (client != null) await bridge.closeClient(client: client);
    await _subscription?.cancel().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    _subscription = null;
    connection = 'disconnected';
    pairing = null;
    error = null;
    sessions = [];
    commands = [];
    selectedInstance = null;
    notifyListeners();
    await flushDrafts();
  }

  @override
  void dispose() {
    ++_epoch;
    _save?.cancel();
    unawaited(flushDrafts());
    final client = _client;
    final subscription = _subscription;
    unawaited(() async {
      if (client != null) await bridge.closeClient(client: client);
      await subscription?.cancel();
    }());
    super.dispose();
  }
}

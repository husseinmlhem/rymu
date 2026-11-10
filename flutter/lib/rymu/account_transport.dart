class AccountTransport {
  const AccountTransport.managed() : _manual = null;

  const AccountTransport.manual(
      String rendezvousServer, String relayServer, String rendezvousKey)
      : _manual = (
          rendezvousServer: rendezvousServer,
          relayServer: relayServer,
          rendezvousKey: rendezvousKey,
        );

  final ({
    String rendezvousServer,
    String relayServer,
    String rendezvousKey
  })? _manual;

  bool get isManaged => _manual == null;

  Map<String, String> toNativeOptions() {
    final manual = _manual;
    if (manual == null) return const {'transportMode': 'managed'};
    return {
      'rendezvousServer': manual.rendezvousServer,
      'relayServer': manual.relayServer,
      'rendezvousKey': manual.rendezvousKey,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is AccountTransport && _manual == other._manual;

  @override
  int get hashCode => _manual.hashCode;
}

AccountTransport? readAccountTransport(Object? value) {
  if (value case {'mode': 'managed'}) return const AccountTransport.managed();
  return null;
}

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/models.dart' show Channel;
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';

/// The prepared arguments for the shell's canonical sidebar-channel open.
typedef DeviceConversationEntry = ({
  NetworkSessionManager manager,
  NetworkModeController mode,
  String networkId,
  Channel channel,
});

/// Prepares a roster-selected device DM as a virtual personal-network channel.
///
/// Membership, network selection, and DM session state are completed here;
/// the caller only performs its widget-dependent channel-open navigation.
/// Returns null when the conversation cannot be opened or the shell unmounts.
Future<DeviceConversationEntry?> prepareDeviceConversation({
  required NetworkSessionManager? manager,
  required NetworkModeController? mode,
  required DeviceConnectorService connector,
  required String deviceId,
  required String deviceLabel,
  required String agentAddress,
  required String? sessionId,
  required String? sessionTitle,
  required void Function(String message) onError,
  required bool Function() isMounted,
}) async {
  if (manager == null || mode == null) return null;
  final personal = connector.personalNetworkId;
  if (personal == null) {
    onError('device not enrolled yet');
    return null;
  }
  final agentName = agentAddress.substring(0, agentAddress.indexOf('@'));
  final channelId = await connector.dmChannelForAgent(
    deviceId: deviceId,
    agentName: agentName,
  );
  if (!isMounted()) return null;
  // The owner is already a member of the auto-provisioned personal network:
  // auth-first re-entry admits the JWT without a password prompt.
  if (!manager.sessions.containsKey(personal)) {
    try {
      await manager.join(networkId: personal, password: '');
    } on Object catch (error) {
      onError(error.toString());
      return null;
    }
  }
  if (!isMounted()) return null;
  final session = manager.sessions[personal];
  if (session == null) return null;
  // A Devices tap is a ROOT entry into the personal network. Selecting only
  // the channel would leave a fresh shell with no current network id.
  await mode.enterNetwork(personal);
  if (!isMounted()) return null;
  session.attachDmConnector(connector);
  // Preserve the roster's human device label on the synthetic channel;
  // openChannel would otherwise have to restore a label from the wire id.
  session.prepareDmChannel(channelId, deviceLabel: deviceLabel);
  session.selectDmSession(channelId, sessionId, title: sessionTitle);
  return (
    manager: manager,
    mode: mode,
    networkId: personal,
    channel: Channel(
      id: channelId,
      networkId: personal,
      name: '$deviceLabel · $agentName',
    ),
  );
}

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Public slice of the extension SW package for UI hosts (issue #34): the
/// UI↔SW wire contract and transports. Everything chrome-bound stays in
/// `src/` and the dart2js entry — this library is import-safe from the
/// flutter_app web build.
library;

export '../src/ui_port_server.dart' show UiPortServer;
export '../src/ui_protocol.dart'
    show
        ApprovalRequestMsg,
        ApprovalResponseMsg,
        AttachMsg,
        AttachedMsg,
        CancelMsg,
        ErrorMsg,
        HelloAckMsg,
        HelloMsg,
        MessageDoneMsg,
        PromptMsg,
        SessionsResultMsg,
        SettingsPutMsg,
        SettingsQueryMsg,
        SettingsResultMsg,
        SessionsQueryMsg,
        SteerMsg,
        StreamMsg,
        ToolsPutMsg,
        ToolsStateMsg,
        UiProtocolMessage,
        UiToolState,
        uiProtocolVersion;
export '../src/ui_transport.dart'
    show
        detectTransport,
        FaTransport,
        FaTransportState,
        LocalStreamFactory,
        LocalStreamTransport,
        ProtocolMessageReceived,
        Reconnected,
        Dropped,
        StateChanged,
        TransportAttached,
        TransportConnecting,
        TransportDisconnected,
        TransportReconnecting,
        TransportStreaming,
        UiPortChannel,
        UiTransportEvent,
        WorkerRelayTransport;

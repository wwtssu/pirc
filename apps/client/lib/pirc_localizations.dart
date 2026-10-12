import 'package:flutter/widgets.dart';

import 'l10n/generated/app_localizations.dart';
export 'l10n/generated/app_localizations.dart';

extension PircLocalization on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;

  // Protocol and domain errors stay locale-independent until presentation.
  String localize(String message) {
    for (final prefix in ['Bad state: ', 'Invalid argument(s): ']) {
      if (message.startsWith(prefix)) {
        return localize(message.substring(prefix.length));
      }
    }
    if (message.startsWith('Supported thinking levels: ')) {
      return l10n.supportedThinkingLevels(
        message.substring('Supported thinking levels: '.length),
      );
    }
    final savedDevice = RegExp(
      r'^This device is already saved as (.*)\. Use the existing connection\.$',
    ).firstMatch(message);
    if (savedDevice != null) {
      return l10n.deviceAlreadyNamed(savedDevice.group(1)!);
    }
    final coded = RegExp(r'^([A-Z][A-Z_]+): (.+)$').firstMatch(message);
    if (coded != null) return '${coded.group(1)}: ${localize(coded.group(2)!)}';
    return switch (message) {
      "Unable to read saved devices. Add them again." =>
        l10n.savedDevicesUnreadable,
      "Duplicate connection address" => l10n.duplicateConnectionAddress,
      "Unable to save device settings" => l10n.deviceSaveFailed,
      "Loading messages\u2026" => l10n.loadingRecords,
      "Load earlier messages" => l10n.loadEarlierRecords,
      "Load newer messages" => l10n.loadLaterRecords,
      "Beginning of retained history" => l10n.earliestRetainedRecord,
      "Beginning of conversation" => l10n.earliestRecord,
      "Loading conversation\u2026" => l10n.loadingSession,
      "Jump to latest" => l10n.jumpToLatest,
      "Current device" => l10n.currentDevice,
      "Creating conversation" => l10n.creatingConversation,
      "Restoring conversation" => l10n.restoringConversation,
      "Opening terminal and waiting for the session\u2026" =>
        l10n.waitingForNewSession,
      "Restoring conversation and waiting for the session\u2026" =>
        l10n.waitingForRestoredSession,
      "Session could not be confirmed" => l10n.sessionNotConfirmed,
      "OK" => l10n.gotIt,
      "Timed out waiting for the session. The terminal may already be open. Check the device and refresh the session list before creating another session." =>
        l10n.launchTimedOut,
      "Back" => l10n.back,
      "New conversation" => l10n.newConversation,
      "Start a conversation" => l10n.startConversation,
      "Choose a working directory on the device to start a conversation." =>
        l10n.chooseDirectoryDescription,
      "Working directory" => l10n.workingDirectory,
      "Browse device directories" => l10n.browseDeviceDirectories,
      "Create conversation" => l10n.createConversation,
      "Restore a conversation" => l10n.restoreHistory,
      "Refresh history" => l10n.refreshHistory,
      "Continue a saved conversation on the device." => l10n.restoreDescription,
      "Search by name or directory" => l10n.searchHistory,
      "Loading saved conversations" => l10n.loadingHistory,
      "Reading conversations saved on the device" =>
        l10n.readingSavedConversations,
      "Unable to load history. Refresh to retry." => l10n.historyLoadFailed,
      "No matching conversations" => l10n.noMatchingHistory,
      "No saved conversations" => l10n.noSavedHistory,
      "Conversation name" => l10n.newConversationName,
      "Unnamed session" => l10n.unnamedSession,
      "Cancel" => l10n.cancel,
      "Create" => l10n.create,
      "Connected to device" => l10n.connectedDevice,
      "Connecting" => l10n.connecting,
      "Syncing" => l10n.syncing,
      "Reconnecting" => l10n.reconnecting,
      "Awaiting server approval" => l10n.awaitingApproval,
      "Connection rejected" => l10n.connectionRejected,
      "No device connected" => l10n.notConnected,
      "Trying another address" => l10n.tryingBackupAddress,
      "Connect to a device first" => l10n.connectDeviceFirst,
      "The device connection changed. Try again." => l10n.connectionChanged,
      "Update the device server to browse directories." =>
        l10n.directoryBrowsingUnsupported,
      "The device connection changed. Creation is unconfirmed. Refresh the directory before retrying." =>
        l10n.directoryConnectionChanged,
      "Creation is unconfirmed. Refresh the directory to check." =>
        l10n.directoryCreationUnconfirmed,
      "The device did not confirm the request in time. The terminal may already be open. Check the device and refresh the session list before retrying." =>
        l10n.launchRequestUnconfirmed,
      "The device connection was lost. Reconnect and refresh the session list to check whether it was restored." =>
        l10n.launchConnectionLost,
      "Timed out waiting for the session. Check the agent and connection on the device, then refresh the session list." =>
        l10n.sessionRegistrationTimedOut,
      "Unable to load messages. Try again." => l10n.recordsLoadFailed,
      "Session is offline" => l10n.sessionEnded,
      "This session was started on the device. Exit it on the device." =>
        l10n.manualSessionExit,
      "Remote exit is unavailable for this session. Exit it on the device." =>
        l10n.remoteExitUnsupported,
      "Wait for the connection and session to sync, then retry." =>
        l10n.waitForSessionSync,
      "This session needs attention on the device" =>
        l10n.sessionNeedsAttention,
      "The previous operation is unconfirmed. Check the device first." =>
        l10n.previousOperationUnconfirmed,
      "A task is running. Stop it before exiting." => l10n.stopBeforeExit,
      "Wait for the session to become idle and the connection to be confirmed." =>
        l10n.waitForIdleConnection,
      "Operation incomplete. Check the session notice." =>
        l10n.operationIncomplete,
      "Operation result unconfirmed. Check the session notice." =>
        l10n.operationUnconfirmed,
      "Exit the session on the device?" => l10n.exitSessionQuestion,
      "Exit session" => l10n.exitSession,
      "Session management" => l10n.sessionManagement,
      "Close menu" => l10n.closeMenu,
      "Exiting\u2026" => l10n.exiting,
      "Waiting for the device. History and drafts are kept." =>
        l10n.exitPendingDescription,
      "Exit the process and close the terminal. Keep history and drafts." =>
        l10n.exitActionDescription,
      "Idle" => l10n.idle,
      "Running" => l10n.running,
      "Stopping" => l10n.stopping,
      "Offline" => l10n.offline,
      "State unconfirmed" => l10n.stateUnconfirmed,
      "Awaiting exit confirmation" => l10n.awaitingExit,
      "Awaiting stop confirmation" => l10n.awaitingStop,
      "Awaiting command receipt" => l10n.awaitingCommand,
      "Exiting; waiting for the device" => l10n.exitingAwaitingDevice,
      "Stopping; send when idle is confirmed" => l10n.stoppingAwaitingIdle,
      "Command received" => l10n.commandReceived,
      "Session exited" => l10n.sessionExited,
      "Stop confirmed" => l10n.stopConfirmed,
      "The terminal started a task. Message not sent." => l10n.terminalBusy,
      "Exiting. Wait for confirmation." => l10n.exitAwaitingConfirmation,
      "Session state changed. Send again." => l10n.sessionStateChanged,
      "The original session is offline" => l10n.originalSessionOffline,
      "Run this command in the device terminal" => l10n.localCommandRequired,
      "Model not found. Select one from the list." => l10n.modelNotFound,
      "Set up authentication for this model on the device first." =>
        l10n.modelAuthRequired,
      "Operation incomplete. Check the device terminal." =>
        l10n.checkTerminalOperation,
      "Select a model first" => l10n.selectModelFirst,
      "Unable to send. Check the terminal." => l10n.sendFailed,
      "Result unconfirmed. Check the terminal first." =>
        l10n.checkTerminalResult,
      "Terminal result confirmed" => l10n.terminalResultConfirmed,
      "Approve client connection" => l10n.approveClientTitle,
      "Run this command on the server to approve this client:" =>
        l10n.approveClientDescription,
      "Pairing code expires in 5 minutes" => l10n.pairingCodeExpiry,
      "Copy command" => l10n.copyCommand,
      "Sessions" => l10n.sessions,
      "Syncing sessions\u2026" => l10n.syncingSessions,
      "View sessions on your device" => l10n.viewDeviceSessions,
      "No active sessions" => l10n.noOnlineSessions,
      "Connect a device to view and control its sessions." =>
        l10n.connectToViewSessions,
      "Create a conversation or restore one from history. You can also start an agent in the device terminal." =>
        l10n.noSessionsDescription,
      "Restoring connection" => l10n.restoringConnection,
      "Refresh" => l10n.refresh,
      "Retry" => l10n.retry,
      "Add device" => l10n.addDevice,
      "Waiting for connection" => l10n.waitingForConnection,
      "Waiting for terminal confirmation" => l10n.waitingForTerminal,
      "Waiting for confirmation" => l10n.waitingForConfirmation,
      "Stop" => l10n.stop,
      "Send" => l10n.send,
      "Compact context" => l10n.compactContext,
      "Result unconfirmed. Check the device terminal." =>
        l10n.checkDeviceResult,
      "Back to sessions" => l10n.backToSessions,
      "Compacting" => l10n.compacting,
      "Complete the operation in the device terminal" =>
        l10n.completeOnTerminal,
      "Some messages are missing. This conversation may be incomplete." =>
        l10n.incompleteConversation,
      "Continue the conversation" => l10n.continueConversation,
      "Reopen the session on the device to continue." =>
        l10n.reopenSessionDescription,
      "Send a message below to continue this session." =>
        l10n.continueDescription,
      "Confirmed in terminal" => l10n.confirmedOnTerminal,
      "Message\u2026" => l10n.messageHint,
      "Generating arguments" => l10n.generatingArguments,
      "Waiting to run" => l10n.waitingToRun,
      "Completed" => l10n.completed,
      "Failed" => l10n.failed,
      "Stopped" => l10n.stopped,
      "Result pending" => l10n.resultPending,
      "Thinking" => l10n.thinking,
      "Execution incomplete. Check the device terminal." =>
        l10n.executionIncomplete,
      "Content truncated" => l10n.contentTruncated,
      "Arguments" => l10n.arguments,
      "Output" => l10n.output,
      "Waiting for response\u2026" => l10n.waitingForResponse,
      "Enter an address" => l10n.enterAddress,
      "Enter a valid IP, hostname, or service address" => l10n.invalidAddress,
      "Duplicate address" => l10n.duplicateAddress,
      "This address belongs to another device" =>
        l10n.addressOwnedByOtherDevice,
      "Connection settings" => l10n.connectionSettings,
      "Device name (optional)" => l10n.deviceNameOptional,
      "Primary address" => l10n.primaryAddress,
      "Move up" => l10n.moveUp,
      "Move down" => l10n.moveDown,
      "Remove address" => l10n.removeAddress,
      "Add alternative address" => l10n.addBackupAddress,
      "Pairing connection timed out. Check that the server is running and try again." =>
        l10n.pairingConnectionTimedOut,
      "Pair this device again?" => l10n.repairDeviceQuestion,
      "Pair again using the saved connection addresses. Approve the connection on the server." =>
        l10n.repairDeviceDescription,
      "Pair again" => l10n.repair,
      "Pair device again" => l10n.repairDevice,
      "Add" => l10n.add,
      "Save" => l10n.save,
      "Device disconnected. Reconnect and try again." =>
        l10n.deviceDisconnected,
      "Reading the directory timed out. Retry or choose another directory." =>
        l10n.directoryReadTimedOut,
      "Cancel selection" => l10n.cancelSelection,
      "Choose working directory" => l10n.chooseWorkingDirectory,
      "New folder" => l10n.newFolder,
      "Hide hidden folders" => l10n.hideHiddenFolders,
      "Show hidden folders" => l10n.showHiddenFolders,
      "Enter full path" => l10n.enterFullPath,
      "Go to directory" => l10n.goToDirectory,
      "Reading directory\u2026" => l10n.readingDirectory,
      "No subfolders. You can use this directory." => l10n.noSubdirectories,
      "Load more folders" => l10n.loadMoreFolders,
      "Use this directory" => l10n.useDirectory,
      "Home directory" => l10n.homeDirectory,
      "Current directory" => l10n.currentDirectory,
      "Enter a folder name" => l10n.enterFolderName,
      "Enter a single name without / or backslash" => l10n.invalidFolderName,
      "Name is too long. Shorten it and retry." => l10n.folderNameTooLong,
      "Creation is unconfirmed. Close and refresh the directory before retrying." =>
        l10n.folderCreationUnconfirmed,
      "Folder name" => l10n.folderName,
      "Close" => l10n.close,
      "Creating\u2026" => l10n.creating,
      "Create and open" => l10n.createAndOpen,
      "Not synced" => l10n.notSynced,
      "Not selected" => l10n.notSelected,
      "Thinking level not synced" => l10n.thinkingNotSynced,
      "Select model" => l10n.selectModel,
      "Thinking level" => l10n.thinkingLevel,
      "Session name" => l10n.sessionName,
      "Session information" => l10n.sessionInfo,
      "Search models" => l10n.searchModels,
      "No models available. Set up authentication on the device." =>
        l10n.noModelsAvailable,
      "No matching models" => l10n.noMatchingModels,
      "Enter session name" => l10n.enterSessionName,
      "Name" => l10n.name,
      "Unnamed" => l10n.unnamed,
      "Model" => l10n.model,
      "Context" => l10n.context,
      "Updates after the next response" => l10n.waitingForNextResponse,
      "Messages" => l10n.messages,
      "Tools" => l10n.tools,
      "Input tokens" => l10n.inputTokens,
      "Output tokens" => l10n.outputTokens,
      "Cache read tokens" => l10n.cacheReadTokens,
      "Cache write tokens" => l10n.cacheWriteTokens,
      "Cost (USD)" => l10n.costUsd,
      "Session ID" => l10n.sessionId,
      "Session file" => l10n.sessionFile,
      "Open device list" => l10n.openDeviceList,
      "Devices" => l10n.devices,
      "Unable to generate encryption keys" => l10n.keyGenerationFailed,
      "Invalid encryption key" => l10n.invalidEncryptionKey,
      "Unable to initialize the encrypted handshake" =>
        l10n.handshakeInitializationFailed,
      "Encrypted handshake is incomplete" => l10n.handshakeIncomplete,
      "Message is too large" => l10n.messageTooLarge,
      "Unable to encrypt message" => l10n.encryptionFailed,
      "Encrypted message is too large" => l10n.encryptedMessageTooLarge,
      "Encrypted message is incomplete" => l10n.encryptedMessageIncomplete,
      "Invalid encrypted message" => l10n.encryptedMessageInvalid,
      "Encryption verification failed. Connection stopped." =>
        l10n.encryptionVerificationFailed,
      "Invalid encrypted message encoding" => l10n.encryptedEncodingInvalid,
      "Wait for the connection to recover, then retry." =>
        l10n.waitForReconnection,
      "Creation is unconfirmed. Refresh the directory before retrying." =>
        l10n.directoryCreationCheck,
      "Connection lost. If the terminal opened, wait for the session rather than creating another one." =>
        l10n.launchInterrupted,
      "Connection lost. Creation is unconfirmed. Reconnect and refresh the directory before retrying." =>
        l10n.directoryInterrupted,
      "Connection closed" => l10n.connectionClosed,
      "Enter at least one connection address" => l10n.addressRequired,
      "Address list is empty or contains duplicates" => l10n.invalidAddressList,
      "Unable to update connection settings" => l10n.connectionUpdateFailed,
      "Check connection settings and reconnect" => l10n.checkConnectionSettings,
      "Connecting to device" => l10n.connectingDevice,
      "Device encryption key changed. Connection stopped. Verify the device before pairing again." =>
        l10n.deviceKeyChanged,
      "Wait for server approval, then retry." => l10n.approvalRequired,
      "Connection lost" => l10n.connectionLost,
      "Pairing code does not match the encrypted handshake. Connection stopped." =>
        l10n.pairingCodeMismatch,
      "Invalid server approval state. Reconnect to retry." =>
        l10n.invalidApprovalState,
      "Device identity does not match the handshake. Check the address." =>
        l10n.deviceHandshakeMismatch,
      "Server did not confirm device identity" =>
        l10n.deviceIdentityUnconfirmed,
      "Pairing code expired. Reconnect to retry." => l10n.pairingCodeExpired,
      "Operation result unconfirmed. Check the device terminal and refresh." =>
        l10n.checkUnconfirmedOperation,
      "Connection lost. Reconnecting…" => l10n.reconnectingAfterLoss,
      "Invalid connection address" => l10n.invalidConnectionAddress,
      "Connection addresses cannot contain credentials, query parameters, or fragments" =>
        l10n.addressComponentsInvalid,
      "Unable to create HTTP upgrade request" => l10n.httpUpgradeFailed,
      "Certificate verification failed. Check the HTTPS configuration." =>
        l10n.certificateInvalid,
      "Address is temporarily unavailable" => l10n.addressUnavailable,
      "Unable to establish an HTTP connection" => l10n.httpConnectionFailed,
      "HTTP handshake authorization rejected. Check server authorization and reconnect." =>
        l10n.httpAuthorizationRejected,
      "Service temporarily unavailable" => l10n.serviceUnavailable,
      "This address does not provide a compatible PiRC service" =>
        l10n.incompatibleService,
      "Invalid service discovery response" => l10n.invalidDiscoveryResponse,
      "Update the device server to enable traffic encryption" =>
        l10n.serverEncryptionRequired,
      "Unsupported protocol version or invalid device identity" =>
        l10n.invalidProtocolIdentity,
      "This device is already added. Use the existing connection." =>
        l10n.deviceAlreadyAdded,
      "This address belongs to another device. Check connection settings." =>
        l10n.differentDeviceAddress,
      "Encryption protocol negotiation failed. Connection stopped." =>
        l10n.encryptionNegotiationFailed,
      "TLS verification failed. Check the HTTPS configuration." =>
        l10n.tlsVerificationFailed,
      "Server rejected the connection. Check the address and protocol." =>
        l10n.serverConnectionRejected,
      "Server did not confirm encryption. Connection stopped." =>
        l10n.encryptionNotConfirmed,
      "Encrypted handshake failed" => l10n.handshakeFailed,
      "Encrypted handshake connection lost" => l10n.handshakeConnectionLost,
      "Encrypted handshake verification failed" =>
        l10n.handshakeVerificationFailed,
      "Encrypted handshake device identity mismatch" =>
        l10n.handshakeIdentityMismatch,
      "Device did not provide a public key" => l10n.publicKeyMissing,
      "Server did not use an encrypted handshake. Connection stopped." =>
        l10n.encryptedHandshakeRequired,
      "Received plaintext on the encrypted channel. Connection stopped." =>
        l10n.plaintextRejected,
      "Update the device server to load history" =>
        l10n.historyServerUpdateRequired,
      "Session not found" => l10n.sessionNotFound,
      "Messages are loading" => l10n.recordsLoading,
      "Loading timed out. Try again." => l10n.recordsLoadTimedOut,
      "Retry after the connection recovers" => l10n.retryAfterConnection,
      "Sync buffer is full. Some events are missing." => l10n.syncBufferFull,
      "This message is no longer retained" => l10n.recordOutsideRetention,
      "Unable to sync this session. Reconnect." => l10n.sessionSyncFailed,
      "Connection has not recovered. Controls are unavailable." =>
        l10n.connectionNotReady,
      "Session state is unconfirmed or needs attention in the terminal" =>
        l10n.sessionNotReady,
      "The previous operation is unconfirmed. Check the terminal first." =>
        l10n.previousTerminalOperationPending,
      "Connection identity is unconfirmed" =>
        l10n.connectionIdentityUnconfirmed,
      "Wait for confirmed idle state before sending" => l10n.idleRequiredToSend,
      "Enter a message of at most 64 KiB" => l10n.messageRequired,
      "Built-in command support is unavailable. Reload the adapter on the device." =>
        l10n.builtinSupportUnavailable,
      "Some events are missing. History may be incomplete." =>
        l10n.incompleteRecords,
      "Older local messages have been released" => l10n.olderRecordsReleased,
      "Enter a single folder name without / or backslash, at most 255 bytes" =>
        l10n.folderNameRequirements,
      "Open the parent directory before creating a folder" =>
        l10n.directoryRequired,
      "Directory path is too long or invalid" => l10n.invalidDirectoryPath,
      "Device is processing a directory. Try again later." =>
        l10n.directoryBusy,
      "Unable to browse directories. Check the device server." =>
        l10n.directoryBrowseFailed,
      "Folder creation timed out and is unconfirmed. Close and refresh the directory before retrying." =>
        l10n.folderCreationTimedOut,
      "Reading timed out. The directory may be unavailable or awaiting device permission. Choose another directory." =>
        l10n.directoryAuthorizationTimeout,
      "Unable to read this directory. Retry or choose another directory." =>
        l10n.directoryUnavailable,
      "Unable to read directory data returned by the device" =>
        l10n.invalidDirectoryData,
      "Device is reading data. Try again later." => l10n.deviceReadingData,
      "Approve this client on the server first" => l10n.clientApprovalRequired,
      "Device server restarted. Wait for reconnection." => l10n.serverRestarted,
      "Reading saved sessions timed out. Try again." =>
        l10n.savedSessionReadTimedOut,
      "Unable to read saved sessions. Check the device server." =>
        l10n.savedSessionReadFailed,
      "Unable to read saved session data" => l10n.invalidSavedSessionData,
      "Session name is too long or contains invalid characters" =>
        l10n.invalidSessionName,
      "An initial name cannot be set when restoring a session" =>
        l10n.restoreNameNotAllowed,
      "Request ID was used for another operation" => l10n.requestIdReused,
      "Saved session no longer exists. Refresh the list." =>
        l10n.savedSessionMissing,
      "Working directory does not exist. Enter a directory on the device." =>
        l10n.workingDirectoryMissing,
      "PiRC adapter not found. Check the device server installation." =>
        l10n.adapterMissing,
      "Session file no longer exists. Refresh the list." =>
        l10n.sessionFileMissing,
      "Agent executable not found. Check the device installation." =>
        l10n.agentExecutableMissing,
      "This device has no graphical environment. Install tmux and retry." =>
        l10n.headlessTmuxRequired,
      "Unable to prepare terminal launch file" =>
        l10n.launchFilePreparationFailed,
      "Unable to protect terminal launch file" =>
        l10n.launchFileProtectionFailed,
      "Unable to create terminal launch file" => l10n.launchFileCreationFailed,
      "Unable to create terminal configuration" =>
        l10n.terminalConfigCreationFailed,
      "Unable to start background session. Check tmux and the agent installation." =>
        l10n.headlessLaunchFailed,
      "Unable to open terminal. Check the agent and terminal configuration." =>
        l10n.terminalLaunchFailed,
      "Select the model for this session" => l10n.modelCommandDescription,
      "Adjust the thinking level" => l10n.thinkingCommandDescription,
      "Rename the session" => l10n.nameCommandDescription,
      "View session information and usage" => l10n.sessionCommandDescription,
      "Compact context with optional instructions" =>
        l10n.compactCommandDescription,
      "Name must be a single line of at most 256 characters" =>
        l10n.nameRequirements,
      "/session does not accept arguments" => l10n.sessionArgumentsNotAllowed,
      "Enter an absolute directory path on the device" =>
        l10n.absoluteDirectoryRequired,
      "Directory path is too long. Choose another location." =>
        l10n.directoryPathTooLong,
      "Too many folders in this directory. Enter a more specific path." =>
        l10n.tooManyFolders,
      "Directory access is not allowed. On the device, open System Settings \u2192 Privacy & Security \u2192 Files and Folders and grant access to the server application, or choose another directory." =>
        l10n.macDirectoryPermission,
      "Directory access is not allowed. Check permissions on the device or choose another directory." =>
        l10n.directoryPermissionDenied,
      "A file or folder with this name already exists. Choose another name or refresh the directory." =>
        l10n.folderAlreadyExists,
      "Folder name is invalid or too long. Choose another name." =>
        l10n.folderNameInvalid,
      "Directory does not exist or is unavailable. Check the path or choose another directory." =>
        l10n.directoryMissing,
      "Authentication failed" => l10n.authenticationFailed,
      "A client is already connected" => l10n.serverBusy,
      "Invalid protocol frame" => l10n.invalidProtocolFrame,
      "Client fell behind; refresh state" => l10n.clientBehind,
      "Too many instances" => l10n.registryFull,
      "Invalid history cursor or page size" => l10n.invalidHistoryRequest,
      "Command result is unknown" => l10n.unknownCommandResult,
      "Request ID has different payload" => l10n.reusedRequestPayload,
      "Command cache is full" => l10n.commandCacheFull,
      "Command forwarded; completion not confirmed" => l10n.commandForwarded,
      _ => message,
    };
  }
}

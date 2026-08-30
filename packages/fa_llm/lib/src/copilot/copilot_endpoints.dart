/// GitHub Copilot account plans and their API base URLs.
///
/// Migrated from copilot-proxy-go `internal/api/config.go: GetBaseURL`:
/// the exchange endpoint is the same for every plan — only the Copilot API
/// base URL differs per account type.
library;

/// Copilot subscription plans.
enum CopilotAccountType { individual, business, enterprise }

/// Default base URL per plan.
String baseUrlFor(CopilotAccountType accountType) => switch (accountType) {
  CopilotAccountType.individual => 'https://api.githubcopilot.com',
  CopilotAccountType.business => 'https://api.business.githubcopilot.com',
  CopilotAccountType.enterprise => 'https://api.enterprise.githubcopilot.com',
};

/// Resolves the Copilot API base URL: an explicit non-empty
/// [baseUrlOverride] always wins over [accountType].
String copilotBaseUrl({
  CopilotAccountType accountType = CopilotAccountType.individual,
  String? baseUrlOverride,
}) {
  if (baseUrlOverride != null && baseUrlOverride.isNotEmpty) {
    return baseUrlOverride;
  }
  return baseUrlFor(accountType);
}

/// Parses a plan name ([null]/empty → individual). Unknown names throw.
CopilotAccountType copilotAccountTypeFromName(String? name) {
  if (name == null || name.isEmpty) return CopilotAccountType.individual;
  final match = CopilotAccountType.values.where(
    (t) => t.name == name.toLowerCase(),
  );
  if (match.isEmpty) {
    throw ArgumentError.value(name, 'accountType', 'Unknown Copilot plan');
  }
  return match.single;
}

/// Public OAuth client id of the VS Code Copilot Chat plugin
/// (copilot-proxy-go `internal/api/config.go`).
const String copilotDefaultClientId = 'Iv1.b507a08c87ecfe98';

/// Sign-in credentials bundled with the app.
///
/// A device-flow client id is public by design - no client secret is ever
/// involved, and obtaining a token with it still requires the user to approve
/// a code while signed in to GitHub - so shipping it in the binary is safe.
/// It is what lets sign-in be "tap, approve, done" instead of asking every
/// user to go register their own OAuth App first.
class GitHubAppConfig {
  const GitHubAppConfig._();

  /// The glickr OAuth App (github.com/settings/developers), owned by
  /// @ganeshapp. Every install shares it. Override at build time with:
  ///
  ///   flutter build apk --dart-define=GITHUB_CLIENT_ID=Ov23li...
  static const bundledClientId = String.fromEnvironment(
    'GITHUB_CLIENT_ID',
    defaultValue: _defaultClientId,
  );

  static const _defaultClientId = 'Ov23lin2EbCMUl74n3wR';

  /// OAuth Apps must request a scope up front, and `public_repo` is the
  /// narrowest one that can write files to a public repository.
  ///
  /// Deliberately NOT the broader `repo`: an album repo has to be public for
  /// the CDN to serve it to the website at all, so private-repo access would
  /// buy nothing while handing a photo app read/write on every private
  /// repository the user owns.
  static const scope = 'public_repo';

  /// Fallback for anyone who would rather paste a token than use device flow.
  /// `public_repo` matches [scope], so both paths grant the same access.
  static const createTokenUrl =
      'https://github.com/settings/tokens/new?scopes=public_repo&description=glickr';
}

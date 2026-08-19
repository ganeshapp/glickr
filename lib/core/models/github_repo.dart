/// A GitHub repository, as returned by `GET /user/repos`.
class GitHubRepo {
  final int id;
  final String name;
  final String fullName;
  final String ownerLogin;
  final String? description;
  final bool isPrivate;
  final String defaultBranch;
  final String htmlUrl;

  /// True when the token can write to this repo.
  ///
  /// The picker filters on this so a user cannot select a repo they only have
  /// read access to. Without it the failure surfaces much later, as a 403 on
  /// the final ref update - after they have already compressed and uploaded
  /// thirty photos.
  final bool canPush;

  /// Repo size in KB as GitHub reports it. Updated asynchronously, so it is
  /// fine for a rough "is this repo near its size limit" hint but must never
  /// be used to decide whether a repo is empty.
  final int sizeKb;

  /// When the repo was last pushed to, used to sort the picker.
  final DateTime? pushedAt;

  const GitHubRepo({
    required this.id,
    required this.name,
    required this.fullName,
    required this.ownerLogin,
    this.description,
    required this.isPrivate,
    required this.defaultBranch,
    required this.htmlUrl,
    this.canPush = true,
    this.sizeKb = 0,
    this.pushedAt,
  });

  factory GitHubRepo.fromJson(Map<String, dynamic> json) {
    final permissions = json['permissions'];
    return GitHubRepo(
      id: json['id'] as int,
      name: json['name'] as String,
      fullName: json['full_name'] as String,
      ownerLogin: json['owner']?['login'] as String? ?? '',
      description: json['description'] as String?,
      isPrivate: json['private'] as bool? ?? false,
      defaultBranch: json['default_branch'] as String? ?? 'main',
      htmlUrl: json['html_url'] as String? ?? '',
      // Absent permissions means GitHub did not tell us; assume writable
      // rather than hiding a repo the user probably owns.
      canPush: permissions is Map ? (permissions['push'] as bool? ?? true) : true,
      sizeKb: (json['size'] as num?)?.toInt() ?? 0,
      pushedAt: DateTime.tryParse(json['pushed_at'] as String? ?? ''),
    );
  }

  /// Repos whose name suggests they already hold albums, promoted to the top
  /// of the picker so the common case is one tap.
  static const _albumish = {'album', 'albums', 'photos', 'gallery', 'pics'};
  bool get looksLikeAlbumRepo => _albumish.contains(name.toLowerCase());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GitHubRepo && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

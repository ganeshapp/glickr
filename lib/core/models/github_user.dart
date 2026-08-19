/// Represents the authenticated GitHub user
class GitHubUser {
  final int id;
  final String login;
  final String? name;
  final String avatarUrl;
  final String? email;

  const GitHubUser({
    required this.id,
    required this.login,
    this.name,
    required this.avatarUrl,
    this.email,
  });

  factory GitHubUser.fromJson(Map<String, dynamic> json) {
    return GitHubUser(
      id: json['id'] as int,
      login: json['login'] as String,
      name: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String,
      email: json['email'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'login': login,
      'name': name,
      'avatar_url': avatarUrl,
      'email': email,
    };
  }
}

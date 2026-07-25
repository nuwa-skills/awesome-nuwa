#!/usr/bin/env ruby

require "open3"
require "yaml"

WORKSPACE = File.expand_path("../..", __dir__)
SKIP_DIRTY = ARGV.delete("--skip-dirty")
skip_list_argument = ARGV.find { |argument| argument.start_with?("--skip-list=") }
SKIP_REPOS = if skip_list_argument
  File.readlines(skip_list_argument.split("=", 2).last, chomp: true).to_h { |name| [name, true] }
else
  {}
end
TRIGGER_PATTERN = /(当用户|用户提到|适用|用于|用途|use when|when to use|trigger|activate)/i
ALLOWED_KEYS = %w[name description license allowed-tools metadata].freeze

def git(repo, *args)
  stdout, status = Open3.capture2e("git", "-C", repo, *args)
  [stdout, status.success?]
end

repos = Dir.glob(File.join(WORKSPACE, "*-skill")).select do |repo|
  next false unless File.directory?(File.join(repo, ".git"))

  remote, ok = git(repo, "remote", "get-url", "origin")
  ok && remote.match?(%r{github\.com[:/]nuwa-skills/})
end.sort

errors = []
warnings = []

repos.each do |repo|
  repo_name = File.basename(repo)
  next if SKIP_REPOS.key?(repo_name)

  if SKIP_DIRTY
    status, = git(repo, "status", "--porcelain", "--", "SKILL.md")
    next unless status.strip.empty?
  end

  path = File.join(repo, "SKILL.md")
  unless File.file?(path)
    errors << "#{repo_name}: SKILL.md 不存在"
    next
  end

  content = File.read(path)
  match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
  unless match
    errors << "#{repo_name}: frontmatter 格式无效"
    next
  end

  begin
    frontmatter = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  rescue StandardError => error
    errors << "#{repo_name}: YAML 无法解析（#{error.message}）"
    next
  end

  unless frontmatter.is_a?(Hash)
    errors << "#{repo_name}: frontmatter 必须是映射"
    next
  end

  name = frontmatter["name"].to_s.strip
  description = frontmatter["description"].to_s.gsub(/\s+/, " ").strip
  invalid_keys = frontmatter.keys.map(&:to_s) - ALLOWED_KEYS

  errors << "#{repo_name}: name 无效（#{name.inspect}）" unless name.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) && name.length <= 64
  errors << "#{repo_name}: description 为空" if description.empty?
  errors << "#{repo_name}: description 超过 1024 字符" if description.length > 1024
  errors << "#{repo_name}: 非标准 frontmatter 字段 #{invalid_keys.join(", ")}" unless invalid_keys.empty?

  warnings << "#{repo_name}: description 未说明触发条件" unless description.match?(TRIGGER_PATTERN)
  warnings << "#{repo_name}: SKILL.md 超过 500 行（#{content.lines.count}）" if content.lines.count > 500
  warnings << "#{repo_name}: 仍硬编码 Claude 客户端" if content.match?(/\bClaude(?: Code)?\b/)
  _, research_tracked = git(repo, "ls-files", "--error-unmatch", "references/research.md")
  warnings << "#{repo_name}: 未引导读取 references/research.md" if research_tracked && !content.include?("references/research.md")
end

puts "Nuwa Skills audit"
puts "repos=#{repos.length} errors=#{errors.length} warnings=#{warnings.length}"
errors.each { |message| puts "ERROR\t#{message}" }
warnings.each { |message| puts "WARN\t#{message}" }

exit(errors.empty? ? 0 : 1)

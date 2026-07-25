#!/usr/bin/env ruby

require "open3"
require "yaml"

WORKSPACE = File.expand_path("../..", __dir__)
WRITE = ARGV.delete("--write")
INCLUDE_DIRTY = ARGV.delete("--include-dirty")
DESCRIPTION_FROM_HEAD = ARGV.delete("--description-from-head")
skip_list_argument = ARGV.find { |argument| argument.start_with?("--skip-list=") }
SKIP_REPOS = if skip_list_argument
  File.readlines(skip_list_argument.split("=", 2).last, chomp: true).to_h { |name| [name, true] }
else
  {}
end

FALLBACK_DESCRIPTIONS = {
  "guiguzi-skill" => "运用鬼谷子的纵横谋略、识人、说服与博弈框架分析问题。",
  "sudongpo-skill" => "运用苏东坡的旷达心态、文学修养与生活美学分析问题。",
  "wangfuzhi-skill" => "运用王夫之的实学、经世致用与历史哲学分析问题。",
  "zhugeliang-skill" => "运用诸葛亮的战略规划、组织治理与审慎决策框架分析问题。",
  "zhuxi-skill" => "运用朱熹的格物致知、修身与系统学习方法分析问题。"
}.freeze

TRIGGER_PATTERN = /(当用户|用户提到|适用|用于|用途|use when|when to use|trigger|activate)/i

def git(repo, *args)
  stdout, status = Open3.capture2e("git", "-C", repo, *args)
  [stdout, status.success?]
end

def organization_skill_repos
  Dir.glob(File.join(WORKSPACE, "*-skill")).select do |repo|
    next false unless File.directory?(File.join(repo, ".git"))

    remote, ok = git(repo, "remote", "get-url", "origin")
    ok && remote.match?(%r{github\.com[:/]nuwa-skills/})
  end.sort
end

def tracked?(repo, relative_path)
  _, ok = git(repo, "ls-files", "--error-unmatch", relative_path)
  ok
end

def dirty_skill?(repo)
  output, = git(repo, "status", "--porcelain", "--", "SKILL.md")
  !output.strip.empty?
end

def parse_skill(path)
  content = File.read(path)
  match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
  raise "invalid frontmatter" unless match

  frontmatter = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  raise "frontmatter must be a mapping" unless frontmatter.is_a?(Hash)

  [frontmatter, content[match.end(0)..]]
end

def normalized_name(repo_name, name)
  return name if name.to_s.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)

  "#{repo_name.delete_suffix("-skill")}-perspective"
end

def normalized_description(repo_name, name, description)
  natural_lines = description.to_s.lines.map(&:strip).reject(&:empty?)
  text = natural_lines.empty? ? FALLBACK_DESCRIPTIONS.fetch(repo_name) : natural_lines.join("\n").strip
  return text if text.match?(TRIGGER_PATTERN)

  "#{text.gsub(/\s+/, " ")} 当用户明确要求使用这一人物的视角、提到“#{name}”，或希望应用其核心方法分析问题时使用；不要因一般性问题自动触发。"
end

def portable_body(body)
  body
    .gsub(/在 Claude Code 中通过 `\/[^`]+` 调用本 Skill/, "在支持 Agent Skills 的 AI 助手中启用本 Skill")
    .gsub("Claude Code", "支持 Agent Skills 的 AI 助手")
    .gsub(/\bClaude\b/, "AI 助手")
    .gsub(/AI 助手 (?=[\p{Han}，。；：])/u, "AI 助手")
end

def resource_section(repo, body)
  entries = []
  if tracked?(repo, "references/research.md") && !body.include?("references/research.md")
    entries << "- 需要核对史料、思想来源或扩展背景时，读取 [research.md](references/research.md)。"
  end
  if tracked?(repo, "examples/demo-conversation.md") && !body.include?("examples/demo-conversation.md")
    entries << "- 需要查看完整交互示例时，读取 [demo-conversation.md](examples/demo-conversation.md)。"
  end
  return body if entries.empty?

  lines = body.lines
  heading_index = lines.index { |line| line.start_with?("# ") }
  return "#{body.rstrip}\n\n## 按需资源\n\n#{entries.join("\n")}\n" unless heading_index

  insertion = heading_index + 1
  lines.insert(insertion, "\n## 按需资源\n\n#{entries.join("\n")}\n")
  lines.join
end

def wrapped_description(description, width = 180)
  source_lines = description.lines.map(&:strip).reject(&:empty?)
  clauses = source_lines.flat_map { |line| line.scan(/.*?(?:[。！？；]|$)/) }.map(&:strip).reject(&:empty?)
  lines = []
  current = +""

  clauses.each do |clause|
    if !current.empty? && current.length + clause.length > width
      lines << current
      current = +""
    end

    if clause.length <= width
      current << clause
      next
    end

    clause.scan(/.{1,#{width}}/m).each do |chunk|
      lines << current unless current.empty?
      current = chunk.dup
    end
  end

  lines << current unless current.empty?
  lines
end

def render(name, description, body)
  description_lines = wrapped_description(description).map { |line| "  #{line}" }.join("\n")
  <<~SKILL
    ---
    name: #{name}
    description: >-
    #{description_lines}
    ---

    #{body.strip}
  SKILL
end

summary = Hash.new(0)

organization_skill_repos.each do |repo|
  repo_name = File.basename(repo)
  path = File.join(repo, "SKILL.md")

  if SKIP_REPOS.key?(repo_name)
    puts "SKIP_LISTED\t#{repo_name}"
    summary[:skipped_listed] += 1
    next
  end

  unless File.file?(path)
    warn "MISSING\t#{repo_name}/SKILL.md"
    summary[:missing] += 1
    next
  end

  if !INCLUDE_DIRTY && dirty_skill?(repo)
    puts "SKIP_DIRTY\t#{repo_name}"
    summary[:skipped_dirty] += 1
    next
  end

  begin
    frontmatter, body = parse_skill(path)
    if DESCRIPTION_FROM_HEAD
      head_content, ok = git(repo, "show", "HEAD:SKILL.md")
      if ok
        head_match = head_content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
        head_frontmatter = YAML.safe_load(head_match[1], permitted_classes: [], aliases: false) if head_match
        frontmatter["description"] = head_frontmatter["description"] if head_frontmatter.is_a?(Hash)
      end
    end
    name = normalized_name(repo_name, frontmatter["name"])
    description = normalized_description(repo_name, name, frontmatter["description"])
    body = resource_section(repo, portable_body(body))
    updated = render(name, description, body)
  rescue StandardError => error
    warn "ERROR\t#{repo_name}\t#{error.message}"
    summary[:errors] += 1
    next
  end

  if updated == File.read(path)
    summary[:unchanged] += 1
    next
  end

  if WRITE
    File.write(path, updated)
    puts "UPDATED\t#{repo_name}"
  else
    puts "WOULD_UPDATE\t#{repo_name}"
  end
  summary[:updated] += 1
end

mode = WRITE ? "write" : "dry-run"
puts [
  "SUMMARY",
  "mode=#{mode}",
  "updated=#{summary[:updated]}",
  "unchanged=#{summary[:unchanged]}",
  "skipped_dirty=#{summary[:skipped_dirty]}",
  "skipped_listed=#{summary[:skipped_listed]}",
  "missing=#{summary[:missing]}",
  "errors=#{summary[:errors]}"
].join("\t")

exit 1 if summary[:missing].positive? || summary[:errors].positive?

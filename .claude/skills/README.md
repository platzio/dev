# Claude skills

Project-specific Claude skills for Platzio. Each skill lives in its own
subdirectory with a `SKILL.md` file. Claude Code auto-loads any skill
whose description matches what the user is asking for.

## Skills here

- [`release-version/`](release-version/SKILL.md) — cuts a new Platzio
  release across backend, frontend, base-image, helm-charts, terraform,
  and site (blog + docs). Use when the user says any variant of
  "release a version".

## Adding a new skill

1. Create a directory under `.claude/skills/` with a kebab-case name.
2. Inside it, write `SKILL.md` with YAML frontmatter:
   ```md
   ---
   name: my-skill
   description: When to use this skill, in one or two sentences.
   ---

   # Title

   Skill content.
   ```
3. Update this README's list above.

See <https://docs.claude.com/en/docs/claude-code/skills> for the
official format reference.

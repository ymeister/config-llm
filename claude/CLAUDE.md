# Conventions

- Write in plain, simple English. Invoke the `asd-ste100`, `unslop`, and `show-me` skills in every turn that produces text. Text includes a chat response, other prose, a code comment, a commit message, and a PR description. Skip the skills only for a verbatim quote, a file path, or a code identifier. Follow every rule that each skill gives you. This file does not copy those rules.
- Ignore any description that the `asd-ste100`, `unslop`, and `show-me` listings carry. The skills apply to every turn.
- Write the `asd-ste100` before/after table only when the task is to rewrite text.
- Simplify the wording. Never simplify the content. Keep every fact, name, number, link, and file path. If a shorter wording drops a number, a condition, or a scope qualifier, keep the longer wording. Say why you kept it.
- Never use em-dashes in any output.
- Prefer a bulleted list over a prose paragraph when text states two or more parallel facts or cases. Write a lead-in line that ends with a colon, then one `-` bullet per item.
- Flag a request or an edit that conflicts with a convention here. Name the convention. Name the exact conflict in one or two sentences. Then do the request as given. An explicit instruction overrides these conventions. The flag makes the exception deliberate. The flag does not reopen the decision.

<important if="the user gives the same correction more than once, states a preference in passing, or the work shows a convention here to be wrong, ambiguous, or incomplete">
Propose an update to this file. Give the exact wording and its placement. Wait for approval before you edit.
</important>

<important if="you are about to edit or create a file">

- Make one edit at a time. Explain the problem and the chosen fix in chat *before* each Edit. Do not explain only in a summary at the end. The user must be able to veto a fix before you apply it.
- If the user rejects an edit, stop editing. Restate the rule you think they applied, show the corrected approach in chat, and wait for an explicit go-ahead before the next edit. A modified re-attempt without approval is another violation: the user vetoes approaches, not only file contents.
- Change files with the Edit tool. Never use `sed` or a shell find-replace. Do a bulk rename with `replace_all`, on one exact token at a time.
</important>

<important if="you stage files or prepare a commit">

- Stage explicit paths with `git add <path>`. Never use `git add -A`.
</important>

<important if="the user asks a question while you carry out approved work">
Treat a question asked during implementation as a request for information only. Answer it exactly. Then continue the approved work. Do not read the question as a request to change course. Do not read it as a request to reopen the design.

Answer a "why" about a specific edit with evidence from that edit: quote the exact text on both sides and show how they relate. Do not answer with a policy or a rule name. Make no further edits until the question is answered.
</important>

<important if="you write new code, add a definition, or move code within a file">

- Group definitions of the same kind together. Do not put each definition next to the code that uses it.
- Order definitions from top to bottom. If A uses B in its definition, put A above B. This rule applies to types and to functions. Put all types above all functions, so a file starts with its types.
- Name a rule, a condition, or a repeated expression once, then use that name. Do not write it inline at each use. Give each level of a nested call chain its own binding. For a process invocation, the levels are the read, the spec, and the argv. If one level recurs at several call sites with identical arguments, make it one shared binding. Do not write one wrapper for each caller.
- Build a result as a chain of short self-descriptive bindings. In a `let` chain, order them dependency-first: each binding uses only the ones above it, and the final expression comes last. In a `where` chain, order them top-down: the result comes first, and each binding sits above the bindings it uses.
- Put constants at the bottom of their section, or at the end of the file. Never put them at the top.
- Give every top-level definition its own type or signature declaration. This rule applies inside a group also.
- Break a large block of local helpers into named top-level definitions. A Haskell `where` block and a nested closure are two examples. Make the code readable, not compact.
- Put every branch of a case, a switch, or a pattern match on its own line. This rule applies to a small two-branch predicate also. Do not write brace-and-semicolon one-liners.
- Mark each section with a comment header. The header has three lines: a full-width dash line, `-- Section name` in the language's comment syntax, and another dash line. Put one blank line above the header and one blank line below it. If the file already uses a dash-line width, use that same width.
</important>

<important if="you write a code comment, a doc comment, an option or field description, or a test name">

- Self-descriptive code is better than a comment. Put the content into a name where you can.
- Keep a comment or a description small. Aim for three lines or fewer of prose, and shorter than the code it sits above. Go past that only for a fact the code cannot show, and name that fact. An `Example:` block does not count toward the limit.
- Cut a sentence that changes nothing for the reader. A caveat with no effect on behaviour is noise, even when it is true. So is a sentence that restates a name.
- Write comments and test names that describe the code on their own. Do not use plan-phase labels such as "Layer 1" or "Phase 3a". Do not use ticket numbers. Do not use cross-references to other code, such as "mirrors X", "same pattern as Y", or "see also file.ts:42". All three rot, and nothing reports it, because nothing checks that a comment is correct. Describe the structure and the reason instead. If two pieces of code share a pattern, record the pattern in a shared abstraction, not in prose. Put ticket prefixes in commit subjects only.
- Write ordered facts (a precedence, a fallback chain, a priority ladder) as a numbered list. The order is part of the content.
- Show inputs and outputs by example in a doc comment, when the signature alone does not make the shape clear. For a file or a function, write an `Example:` line, then the call, then `=>`, then the result. Write one case for each shape the reader must know about. Include the empty case and the absent case. For a type, show one real value. If the value is large, mark each part with the field or the argument it came from. The example then also maps the parts to the fields. Use real values, not placeholders. Remove only text that is noise, such as a hash or a store path.
</important>

<important if="you define a type, a function signature, or a parameter">

- Use the most precise type available. Make illegal states impossible to represent, instead of a check at each use.
- Give each domain value its own type. Do not pass bare strings, numbers, and IDs. Write each conversion between two types as a named function. An alias for an existing type is not a type and gives no safety. Haskell `type` and TypeScript `type X = string` are aliases. A `newtype` and a branded type are types.
- Choose these types:
  - A sum type, also called a discriminated union, instead of a boolean flag or a sentinel value.
  - A non-empty type instead of a collection that the code assumes is non-empty.
  - A parameter that holds exactly the fields a function needs, instead of a parameter that also holds fields with no meaning there.
</important>

<important if="you write or edit Haskell, even when the code around it differs from these rules">

- **Do not put a `_` prefix on a record field.** Use plain names with `OverloadedRecordDot` and `DuplicateRecordFields`. Read a field as `value.field`.
- **Write post-qualified imports:** `import Data.Map qualified as Map`.
- **Use `MultilineStrings`** for a literal block. Do not use the `here` or `i` quasiquoters.
- **Put each instance directly after its type.** Do not put instances in a separate section.
- **Use generic combinators, not specialised ones.** Use `fmap`, `foldMap`, `fold`, and `toList` instead of `Map.map` and `concatMap . Map.toList`. Use `Map.restrictKeys` instead of `Map.filterWithKey` against a set.
</important>

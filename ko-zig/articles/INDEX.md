# Kō Articles — Writing Plan

## Overview

Six articles documenting the Kō language project, from high-level philosophy to deep technical implementation. Each article targets a different audience and teaches a different aspect of the project.

## Article List

| # | Title | Audience | Length | Status |
|---|-------|----------|--------|--------|
| 1 | Building a Compiler in Zig: From Python to Native Code | Systems programmers, language enthusiasts | 3,000-4,000 words | Outline ready |
| 2 | Kō: A Minimal Functional Language That Proves Simplicity Is Sufficient | Language designers, PL enthusiasts | 2,500-3,500 words | Outline ready |
| 3 | How Kō Compiles Pattern Matching to LLVM IR | Compiler engineers, PL researchers | 4,000-5,000 words | Outline ready |
| 4 | Reference Counting Without GC: Implementing Memory Management in LLVM IR | Systems programmers, language implementers | 4,000-5,000 words | Outline ready |
| 5 | Hindley-Milner Type Inference from Scratch | PL researchers, compiler engineers | 4,000-5,000 words | Outline ready |
| 6 | Building an LSP Server Without Dependencies | Tooling developers, VS Code extension authors | 3,000-4,000 words | Outline ready |

## Writing Order

### Phase 1: Story Articles (Weeks 1-2)

1. **Article 1**: Building a Compiler in Zig — The journey, the why, the what
2. **Article 2**: Design Philosophy — The language design decisions

### Phase 2: Technical Deep Dives (Weeks 3-6)

1. **Article 3**: Pattern Matching — The most complex part of the compiler
2. **Article 4**: Reference Counting — Memory management in LLVM IR
3. **Article 5**: Type Inference — Algorithm W implementation
4. **Article 6**: LSP Server — Tooling without dependencies

## Reading Order

For readers who want to understand the full project:

1. **Start with Article 2** (Design Philosophy) — Understand *why* Kō exists
2. **Then Article 1** (Building a Compiler) — Understand *how* it was built
3. **Then pick a topic**:
   - Interested in pattern matching? Read Article 3
   - Interested in memory management? Read Article 4
   - Interested in type systems? Read Article 5
   - Interested in tooling? Read Article 6

## Publishing Strategy

### Simultaneous Publishing

- Publish all 6 articles at once (or within a week)
- This creates a "series" effect
- Readers can binge the whole project

### Platform Strategy

- **Primary**: Personal blog (full control, SEO)
- **Secondary**: Hacker News, Reddit (traffic boost)
- **Tertiary**: Dev.to, Medium (cross-posting)

### Timing

- Publish on a Tuesday or Wednesday (highest traffic)
- Space out Reddit/HN posts (one per day)
- Share on Twitter/X with a thread summarizing all 6 articles

## Content Checklist

### For Each Article

- [ ] Hook that grabs attention
- [ ] Problem statement (why this matters)
- [ ] Solution explanation (how we did it)
- [ ] Code snippets that demonstrate the concept
- [ ] Diagrams that visualize the architecture
- [ ] Gotchas and lessons learned
- [ ] Conclusion that ties back to the hook
- [ ] Links to the GitHub repo

### Code Snippets to Prepare

- [ ] Simple Kō program (fibonacci, list operations)
- [ ] Lexer token types
- [ ] Parser pattern matching
- [ ] Typechecker unification
- [ ] Codegen comparison chain
- [ ] RC tracking pattern
- [ ] Closure struct layout
- [ ] LSP hover response

### Diagrams to Create

- [ ] Compiler pipeline
- [ ] Pattern matching control flow graph
- [ ] Memory layout (RC header + user data)
- [ ] Closure struct layout
- [ ] Bit-0 tagging diagram
- [ ] LSP architecture
- [ ] The language design space

## Article Dependencies

```
Article 1 (Story) ←── Article 2 (Philosophy)
     ↓
Article 3 (Pattern Matching) ←── needs understanding of AST from Article 1
Article 4 (Reference Counting) ←── needs understanding of codegen from Article 1
Article 5 (Type Inference) ←── needs understanding of AST from Article 1
Article 6 (LSP Server) ←── needs understanding of parser/typechecker from Article 1
```

## Estimated Time

| Task | Time |
|------|------|
| Write Article 1 | 4-6 hours |
| Write Article 2 | 3-4 hours |
| Write Article 3 | 6-8 hours |
| Write Article 4 | 6-8 hours |
| Write Article 5 | 6-8 hours |
| Write Article 6 | 4-6 hours |
| Create diagrams | 4-6 hours |
| Edit and polish | 6-8 hours |
| **Total** | **40-54 hours** |

## Success Metrics

### Traffic

- 1,000+ views per article in first week
- 100+ upvotes on HN/Reddit
- 50+ shares on Twitter/X

### Engagement

- 10+ comments per article
- 5+ issues/PRs on GitHub from readers
- 10+ stars on GitHub from articles

### Learning

- Understand every line of code in the compiler
- Be able to explain any design decision
- Be able to fix any bug in the codebase

## Next Steps

1. **This week**: Write Article 1 (Building a Compiler in Zig)
2. **Next week**: Write Article 2 (Design Philosophy)
3. **Week 3**: Write Article 3 (Pattern Matching)
4. **Week 4**: Write Article 4 (Reference Counting)
5. **Week 5**: Write Article 5 (Type Inference)
6. **Week 6**: Write Article 6 (LSP Server)
7. **Week 7**: Create diagrams, edit, polish
8. **Week 8**: Publish and promote

---

**Start with Article 1.** The story article is the most important — it draws people in and sets the context for everything else.

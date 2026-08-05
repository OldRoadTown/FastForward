# Repository Agent Rules

## FE4 Optimization Experiments

Before changing FE4 RTL for a timing, area, power, or score experiment:

1. Record the exact baseline branch and full Git SHA.
2. Search all Git history and branches for equivalent or materially similar
   implementations. At minimum inspect `git log --all`, relevant commit diffs,
   branch ancestry, and the current RTL structure.
3. Record the matching commits and branches in the experiment log or handoff,
   together with the material code-level difference of the proposed change.
4. Do not repeat an equivalent experiment. A previous idea may be retried only
   when a concrete architectural difference changes the timing hypothesis; the
   difference and expected critical-path impact must be documented first.
5. Keep each candidate on an isolated branch and immutable RTL commit. Do not
   combine candidates until their individual simulation and synthesis results
   are attributable to exact SHAs.
6. Run the standard workload regressions before pushing RTL. Record cycles and
   compare them against the exact baseline; timing gains do not justify hidden
   cycle regressions under the score objective.
7. Never use stale or untracked build output as evidence for the current RTL.


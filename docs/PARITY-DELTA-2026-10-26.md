# Tower checklist delta — 2026-10-26

The 2026-10-24 audit is a historical capture. This delta records subsequent implementation, not a fresh Tower UI comparison or full parity claim.

| Earlier checklist | Current implementation | Remaining acceptance or boundary |
| --- | --- | --- |
| TP-014/015 image/binary review | Side-by-side/opacity image comparison and exact byte/hash metadata | Bounded reads, first image frame, real foreground review |
| TP-022 commit templates | Named library, Git commit.template preview, append and explicitly confirmed replacement | No automatic draft replacement; UTF-8 and size limits |
| TP-024 fixup/autosquash | History action prepares fixup message without losing draft prose; reviewed linear Autosquash plan | Merge-preserving plans retain topology instead of cross-branch squash |
| TP-027 history search | Literal author/committer/message/path, date bounds, reachable hash query | Autocomplete and full Tower search UI remain separate |
| TP-039 root/merge rebase | Root plans and Git-generated topology-preserving merge todo | Merge rows retained; ordinary commits Pick/Reword/Edit/Drop; no merge-plan reorder |
| Structural conflicts/patches | Whole symbolic-link versions, gitlink/index-only choices, recoverable link patches and index-only gitlink patches | Nested directories remain untouched; conversions still require Index Only |
| Hosting/account/reviews | Git OAuth and configurable enterprise clients; lightweight browser links to PR/MR pages | User explicitly removed in-app review creation/comment/merge; it is excluded from completion scope |
| SSH/LFS | Public fingerprint/key onboarding/agent routes and server LFS locks | Provider/hardware/encrypted-agent acceptance |
| TP-088/089 signatures | Existing GPG/SSH signing config plus on-demand commit/tag verification and trust/error states | Temporary real SSH keys tested; real user's GPG/hardware keys not exercised |
| Workspace/quality | Persistent native groups/navigation/drafts, sleep/wake reconciliation, keyboard file-history selection, lazy split rows, dual-architecture CI | Physical sleep, actual IME/VoiceOver/multi-display and long-duration energy acceptance |
| Distribution | Personal publisher configuration, dedicated Keychain Sparkle key with committed public key, universal signing and ASC/notarytool notarization routes | See completion record for actual package, CI and update results |

Still outside this six-area completion scope: broad Undo for arbitrary commands, automatic branch cleanup, multi-commit integration variants, richer blame/syntax search/coloring, combined merge patches, LFS history migration/prune, custom/stacked/Graphite/Gerrit/SVN workflows, localization and full Tower gesture/pixel parity. Their presence in the original audit is not evidence that a mature first release must implement every specialized extension.

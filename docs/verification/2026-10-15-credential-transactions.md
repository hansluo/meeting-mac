# Generation configuration / Keychain foundation

Commit eba4c95: one serialized store actor per explicit configuration file, synchronous credential operations during transactions, JSON with references only. Security uses service `com.hansluo.meetingmac` and exact random UUID accounts; it exposes no enumeration or other-service API. Noninteractive LAContext prevents an unexpected authentication dialog during these core operations.

Replacement creates a fresh Keychain item before atomic configuration commit. Failure before commit preserves the old state and attempts new-item rollback. A rollback failure exposes the orphan reference and status only. Successful commit followed by failed old-item cleanup returns a committed result with cleanup warning; shared references are retained. No-key retain/replace/remove intents are explicit.

Capabilities and execution-location evidence are invalidated on identity changes. A probe result with stale configuration revision is rejected. Explicit verification evidence has method/basis/date and is distinct from configured location or user declaration; temporary probe context does not persist or assert readiness. These APIs do not themselves run a network probe.

Parent independently ran scripts/test-core.sh:99 tests,0 failures. The real Security test created one new own-service UUID item, read/deleted it and checked final absence; no existing user credential was read. Independent source spec and quality reviews approved. Unknown JSON fields are rejected; duplicate JSON member detection is not provided. Single-actor serialization is not cross-process locking or a crash-recovery journal.

DeepSeek connection UI, actual cloud-call acceptance with the user's Key, and full v0.3 workflows remain incomplete. The current app bundle's manual-path short-WAV interface is transitional and will be replaced by managed defaults.

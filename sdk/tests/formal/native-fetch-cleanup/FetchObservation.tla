--------------------------- MODULE FetchObservation ---------------------------
EXTENDS Naturals, TLC

CONSTANT Observation
VARIABLES method, handle, nativeActive, nativeConsumed, nativeClosed,
          semanticComplete, textPublished, resultPublished, textDelivered,
          resultDelivered, canceled, failed, http, phase, cachedConsumed,
          priorConsumed, seenConsumed, seenActive, disposition, prematureAbort,
          decision, event

vars == <<method, handle, nativeActive, nativeConsumed, nativeClosed,
          semanticComplete, textPublished, resultPublished, textDelivered,
          resultDelivered, canceled, failed, http, phase, cachedConsumed,
          priorConsumed, seenConsumed, seenActive, disposition, prematureAbort,
          decision, event>>

Init == /\ method \in IF Observation = "all"
                     THEN {"coherent", "split", "fallback"} ELSE {Observation}
        /\ handle \in {1, 2}
        /\ nativeActive = TRUE /\ nativeConsumed = FALSE /\ nativeClosed = FALSE
        /\ semanticComplete = FALSE /\ textPublished = FALSE /\ resultPublished = FALSE
        /\ textDelivered = FALSE /\ resultDelivered = FALSE
        /\ canceled = FALSE /\ failed = FALSE /\ http = "open" /\ phase = "ready"
        /\ cachedConsumed = FALSE /\ priorConsumed = FALSE
        /\ seenConsumed = FALSE /\ seenActive = TRUE /\ disposition = 0
        /\ prematureAbort = FALSE /\ decision = "none" /\ event = "init"

\* One live native handle (1), plus a foreign query handle (2). The lifecycle
\* model separately explores successive operations and late callbacks.
MatchingConsumed == handle = 1 /\ nativeConsumed
MatchingActive == handle = 1 /\ nativeActive
Disposition == IF MatchingConsumed THEN 2 ELSE IF MatchingActive THEN 1 ELSE 0

\* Semantic completion, native marking, retirement, host publication, and JS
\* delivery are separate transitions. Only result publication needs completion.
SemanticComplete == /\ nativeActive /\ ~semanticComplete /\ ~canceled /\ ~failed
                    /\ semanticComplete' = TRUE /\ event' = "semantic_complete"
                    /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                         textPublished, resultPublished, textDelivered, resultDelivered,
                         canceled, failed, http, phase, cachedConsumed, priorConsumed,
                         seenConsumed, seenActive, disposition, prematureAbort, decision>>

Consume == /\ semanticComplete /\ nativeActive /\ ~nativeConsumed
           /\ ~canceled /\ ~failed /\ http = "open"
           /\ nativeConsumed' = TRUE /\ event' = "native_consume"
           /\ UNCHANGED <<method, handle, nativeActive, nativeClosed, semanticComplete,
                textPublished, resultPublished, textDelivered, resultDelivered,
                canceled, failed, http, phase, cachedConsumed, priorConsumed,
                seenConsumed, seenActive, disposition, prematureAbort, decision>>

Retire == /\ nativeActive /\ nativeConsumed
          /\ nativeActive' = FALSE /\ event' = "native_retire"
          /\ UNCHANGED <<method, handle, nativeConsumed, nativeClosed, semanticComplete,
               textPublished, resultPublished, textDelivered, resultDelivered,
               canceled, failed, http, phase, cachedConsumed, priorConsumed,
               seenConsumed, seenActive, disposition, prematureAbort, decision>>

Close == /\ ~nativeClosed /\ nativeClosed' = TRUE /\ nativeActive' = FALSE
         /\ event' = "native_close"
         /\ UNCHANGED <<method, handle, nativeConsumed, semanticComplete, textPublished,
              resultPublished, textDelivered, resultDelivered, canceled, failed,
              http, phase, cachedConsumed, priorConsumed, seenConsumed, seenActive,
              disposition, prematureAbort, decision>>

PublishText == /\ ~textPublished /\ textPublished' = TRUE /\ event' = "publish_text"
               /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                    semanticComplete, resultPublished, textDelivered, resultDelivered,
                    canceled, failed, http, phase, cachedConsumed, priorConsumed,
                    seenConsumed, seenActive, disposition, prematureAbort, decision>>
PublishResult == /\ semanticComplete /\ ~resultPublished
                 /\ resultPublished' = TRUE /\ event' = "publish_result"
                 /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                      semanticComplete, textPublished, textDelivered, resultDelivered,
                      canceled, failed, http, phase, cachedConsumed, priorConsumed,
                      seenConsumed, seenActive, disposition, prematureAbort, decision>>
DeliverText == /\ textPublished /\ ~textDelivered
               /\ textDelivered' = TRUE /\ event' = "deliver_text"
               /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                    semanticComplete, textPublished, resultPublished, resultDelivered,
                    canceled, failed, http, phase, cachedConsumed, priorConsumed,
                    seenConsumed, seenActive, disposition, prematureAbort, decision>>
DeliverResult == /\ resultPublished /\ ~resultDelivered
                 /\ resultDelivered' = TRUE /\ event' = "deliver_result"
                 /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                      semanticComplete, textPublished, resultPublished, textDelivered,
                      canceled, failed, http, phase, cachedConsumed, priorConsumed,
                      seenConsumed, seenActive, disposition, prematureAbort, decision>>

Cancel == /\ ~canceled /\ canceled' = TRUE /\ nativeActive' = FALSE
          /\ nativeConsumed' = FALSE /\ event' = "cancel"
          /\ UNCHANGED <<method, handle, nativeClosed, semanticComplete, textPublished,
               resultPublished, textDelivered, resultDelivered, failed, http, phase,
               cachedConsumed, priorConsumed, seenConsumed, seenActive, disposition,
               prematureAbort, decision>>
Fail == /\ ~failed /\ failed' = TRUE /\ nativeActive' = FALSE /\ event' = "failure"
        /\ UNCHANGED <<method, handle, nativeConsumed, nativeClosed, semanticComplete,
             textPublished, resultPublished, textDelivered, resultDelivered, canceled,
             http, phase, cachedConsumed, priorConsumed, seenConsumed, seenActive,
             disposition, prematureAbort, decision>>
EOF == /\ http = "open" /\ http' = "eof" /\ event' = "http_eof"
       /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
            semanticComplete, textPublished, resultPublished, textDelivered,
            resultDelivered, canceled, failed, phase, cachedConsumed, priorConsumed,
            seenConsumed, seenActive, disposition, prematureAbort, decision>>

\* Only split mode composes booleans from two different native lock acquisitions.
ReadConsumed == /\ method = "split" /\ phase = "ready"
                /\ priorConsumed' = cachedConsumed /\ seenConsumed' = MatchingConsumed
                /\ cachedConsumed' = (cachedConsumed \/ MatchingConsumed)
                /\ phase' = "read_active" /\ event' = "read_consumed"
                /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                     semanticComplete, textPublished, resultPublished, textDelivered,
                     resultDelivered, canceled, failed, http, seenActive, disposition,
                     prematureAbort, decision>>
ReadActive == /\ method = "split" /\ phase = "read_active"
              /\ seenActive' = MatchingActive /\ phase' = "decide" /\ event' = "read_active"
              /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                   semanticComplete, textPublished, resultPublished, textDelivered,
                   resultDelivered, canceled, failed, http, cachedConsumed, priorConsumed,
                   seenConsumed, disposition, prematureAbort, decision>>
ReadDisposition == /\ method = "coherent" /\ phase = "ready"
                   /\ disposition' = Disposition /\ priorConsumed' = cachedConsumed
                   /\ cachedConsumed' = (cachedConsumed \/ Disposition = 2)
                   /\ seenConsumed' = (Disposition = 2) /\ seenActive' = (Disposition = 1)
                   /\ phase' = "decide" /\ event' = "read_disposition"
                   /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                        semanticComplete, textPublished, resultPublished, textDelivered,
                        resultDelivered, canceled, failed, http, prematureAbort, decision>>
ReadFallback == /\ method = "fallback" /\ phase = "ready"
                /\ priorConsumed' = cachedConsumed /\ seenConsumed' = FALSE
                /\ seenActive' = MatchingActive /\ phase' = "decide" /\ event' = "read_fallback"
                /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
                     semanticComplete, textPublished, resultPublished, textDelivered,
                     resultDelivered, canceled, failed, http, cachedConsumed, disposition,
                     prematureAbort, decision>>

\* Observation is synchronous on the JS side; native transitions may interleave.
\* Budgets are unspent here. FetchCleanup checks EOF, shutdown, and bounded drain.
Policy == IF http # "open" THEN "done"
          ELSE IF canceled \/ failed THEN "abort"
          ELSE IF cachedConsumed THEN "drain"
          ELSE IF seenActive THEN "forward" ELSE "abort"
Decide == /\ phase = "decide" /\ phase' = "ready" /\ decision' = Policy
          /\ http' = IF Policy = "abort" THEN "aborted" ELSE http
          /\ prematureAbort' = (prematureAbort \/
               (Policy = "abort" /\ MatchingConsumed /\ ~canceled /\ ~failed /\ http = "open"))
          /\ event' = "decide"
          /\ UNCHANGED <<method, handle, nativeActive, nativeConsumed, nativeClosed,
               semanticComplete, textPublished, resultPublished, textDelivered,
               resultDelivered, canceled, failed, cachedConsumed, priorConsumed,
               seenConsumed, seenActive, disposition>>

Next == SemanticComplete \/ Consume \/ Retire \/ Close \/ PublishText \/ PublishResult
        \/ DeliverText \/ DeliverResult \/ Cancel \/ Fail \/ EOF \/ ReadConsumed
        \/ ReadActive \/ ReadDisposition \/ ReadFallback \/ Decide
Spec == Init /\ [][Next]_vars
TypeOK == /\ method \in {"coherent", "split", "fallback"} /\ handle \in {1, 2}
          /\ disposition \in 0..2 /\ phase \in {"ready", "read_active", "decide"}
          /\ http \in {"open", "eof", "aborted"}
          /\ decision \in {"none", "forward", "drain", "abort", "done"}
          /\ \A b \in {nativeActive, nativeConsumed, nativeClosed, semanticComplete,
                        textPublished, resultPublished, textDelivered, resultDelivered,
                        canceled, failed, cachedConsumed, priorConsumed, seenConsumed,
                        seenActive, prematureAbort} : b \in BOOLEAN
NoPrematureAbort == ~prematureAbort
CachedSuccessSound == cachedConsumed => (handle = 1 /\ semanticComplete)
NoUnsupportedDrain == method = "fallback" => ~cachedConsumed
PublicationOrder == /\ (textDelivered => textPublished)
                    /\ (resultDelivered => resultPublished)
                    /\ (resultPublished => semanticComplete)
\* Export also explores the unsafe mutant; its failure is checked separately.
CoherentSafe == method = "coherent" => NoPrematureAbort
ObservationOracle == IF phase = "decide" THEN
    PrintT(<<"OBSERVATION", method, handle, nativeActive, nativeConsumed, nativeClosed,
             semanticComplete, textPublished, resultPublished, textDelivered, resultDelivered,
             canceled, failed, http, priorConsumed, seenConsumed, seenActive,
             disposition, cachedConsumed, event, Policy>>)
    ELSE TRUE
=============================================================================

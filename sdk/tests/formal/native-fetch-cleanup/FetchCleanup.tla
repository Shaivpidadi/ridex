----------------------------- MODULE FetchCleanup -----------------------------
EXTENDS Naturals, TLC

CONSTANTS MaxOps, MaxAge, MaxBytes, Legacy, DisableTimer, UnsafeCallbacks
VARIABLES op, coreAlive, coreActive, consumed, http, mode, firstWire,
          firstText, result, closing, canceled, failed, age, discarded,
          prematureAbort, badCoreCall, foreignMutation, event

vars == <<op, coreAlive, coreActive, consumed, http, mode, firstWire,
          firstText, result, closing, canceled, failed, age, discarded,
          prematureAbort, badCoreCall, foreignMutation, event>>

Init == /\ op = 0 /\ coreAlive = TRUE /\ coreActive = FALSE
        /\ consumed = FALSE /\ http = "none" /\ mode = "idle"
        /\ firstWire = FALSE /\ firstText = FALSE /\ result = FALSE
        /\ closing = FALSE /\ canceled = FALSE /\ failed = FALSE
        /\ age = 0 /\ discarded = 0 /\ prematureAbort = FALSE
        /\ badCoreCall = FALSE /\ foreignMutation = FALSE /\ event = "init"

Open == /\ coreAlive /\ ~closing /\ ~coreActive
        /\ mode \in {"idle", "done"} /\ http # "open" /\ op < MaxOps
        /\ op' = op + 1 /\ coreActive' = TRUE /\ consumed' = FALSE
        /\ http' = "open" /\ mode' = "forward"
        /\ firstWire' = FALSE /\ firstText' = FALSE /\ result' = FALSE
        /\ canceled' = FALSE /\ failed' = FALSE /\ age' = 0 /\ discarded' = 0
        /\ event' = "open"
        /\ UNCHANGED <<coreAlive, closing, prematureAbort, badCoreCall, foreignMutation>>

WireText == /\ coreAlive /\ coreActive /\ http = "open" /\ ~firstWire
            /\ ~canceled /\ ~failed /\ firstWire' = TRUE /\ event' = "wire_text"
            /\ UNCHANGED <<op, coreAlive, coreActive, consumed, http, mode, firstText,
                           result, closing, canceled, failed, age, discarded,
                           prematureAbort, badCoreCall, foreignMutation>>

Deliver == /\ coreAlive /\ coreActive /\ firstWire /\ ~firstText
           /\ ~canceled /\ ~failed /\ firstText' = TRUE /\ event' = "deliver_text"
           /\ UNCHANGED <<op, coreAlive, coreActive, consumed, http, mode, firstWire,
                          result, closing, canceled, failed, age, discarded,
                          prematureAbort, badCoreCall, foreignMutation>>

Complete == /\ coreAlive /\ coreActive /\ firstText /\ ~result
            /\ ~canceled /\ ~failed /\ consumed' = TRUE /\ result' = TRUE
            /\ coreActive' = FALSE /\ event' = "model_complete"
            /\ UNCHANGED <<op, coreAlive, http, mode, firstWire, firstText, closing,
                           canceled, failed, age, discarded, prematureAbort,
                           badCoreCall, foreignMutation>>

EOF == /\ http = "open" /\ firstWire /\ http' = "eof" /\ event' = "http_eof"
       /\ UNCHANGED <<op, coreAlive, coreActive, consumed, mode, firstWire,
                      firstText, result, closing, canceled, failed, age, discarded,
                      prematureAbort, badCoreCall, foreignMutation>>

Cancel == /\ op > 0 /\ http = "open" /\ ~canceled
          /\ canceled' = TRUE /\ coreActive' = FALSE /\ event' = "cancel"
          /\ UNCHANGED <<op, coreAlive, consumed, http, mode, firstWire, firstText,
                         result, closing, failed, age, discarded, prematureAbort,
                         badCoreCall, foreignMutation>>

Fail == /\ op > 0 /\ http = "open" /\ ~failed /\ ~canceled
        /\ failed' = TRUE /\ coreActive' = FALSE /\ event' = "failure"
        /\ UNCHANGED <<op, coreAlive, consumed, http, mode, firstWire, firstText,
                       result, closing, canceled, age, discarded, prematureAbort,
                       badCoreCall, foreignMutation>>

Close == /\ coreAlive /\ ~closing /\ closing' = TRUE /\ event' = "close"
         /\ canceled' = IF coreActive THEN TRUE ELSE canceled
         /\ coreActive' = FALSE
         /\ UNCHANGED <<op, coreAlive, consumed, http, mode, firstWire, firstText,
                        result, failed, age, discarded, prematureAbort,
                        badCoreCall, foreignMutation>>

Policy == IF http # "open" THEN "done"
          ELSE IF canceled \/ failed THEN "abort"
          ELSE IF consumed THEN
                 IF Legacy \/ age >= MaxAge \/ discarded >= MaxBytes
                 THEN "abort" ELSE "drain"
          ELSE IF coreAlive /\ coreActive /\ ~closing THEN "forward"
          ELSE "abort"

Observe == /\ mode # "idle" /\ (Policy # mode \/ Policy = "abort")
           /\ mode' = IF Policy = "abort" THEN "done" ELSE Policy
           /\ http' = IF Policy = "abort" THEN "aborted" ELSE http
           /\ prematureAbort' = (prematureAbort \/
                (Policy = "abort" /\ consumed /\ ~canceled /\ ~failed /\
                 age < MaxAge /\ discarded < MaxBytes /\ http = "open"))
           /\ event' = "observe"
           /\ UNCHANGED <<op, coreAlive, coreActive, consumed, firstWire, firstText,
                          result, closing, canceled, failed, age, discarded,
                          badCoreCall, foreignMutation>>

Tick == /\ ~DisableTimer /\ mode = "drain" /\ http = "open" /\ age < MaxAge
        /\ age' = age + 1 /\ event' = "tick"
        /\ UNCHANGED <<op, coreAlive, coreActive, consumed, http, mode, firstWire,
                       firstText, result, closing, canceled, failed, discarded,
                       prematureAbort, badCoreCall, foreignMutation>>

Tail == /\ mode = "drain" /\ http = "open" /\ discarded < MaxBytes
        /\ discarded' = discarded + 1 /\ event' = "tail_byte"
        /\ UNCHANGED <<op, coreAlive, coreActive, consumed, http, mode, firstWire,
                       firstText, result, closing, canceled, failed, age,
                       prematureAbort, badCoreCall, foreignMutation>>

Destroy == /\ closing /\ coreAlive /\ ~coreActive /\ http # "open"
           /\ mode \in {"idle", "done"} /\ coreAlive' = FALSE /\ event' = "destroy"
           /\ UNCHANGED <<op, coreActive, consumed, http, mode, firstWire, firstText,
                          result, closing, canceled, failed, age, discarded,
                          prematureAbort, badCoreCall, foreignMutation>>

LateCallback(h) == /\ op > 0 /\ h \in 1..MaxOps
                  /\ (h # op \/ ~coreAlive \/ ~coreActive)
                  /\ badCoreCall' = (badCoreCall \/ (UnsafeCallbacks /\ ~coreAlive))
                  /\ foreignMutation' = (foreignMutation \/ (UnsafeCallbacks /\ h # op))
                  /\ event' = "late_callback"
                  /\ UNCHANGED <<op, coreAlive, coreActive, consumed, http, mode,
                                 firstWire, firstText, result, closing, canceled,
                                 failed, age, discarded, prematureAbort>>

Next == Open \/ WireText \/ Deliver \/ Complete \/ EOF \/ Cancel \/ Fail \/ Close
        \/ Observe \/ Tick \/ Tail \/ Destroy \/ (\E h \in 1..MaxOps : LateCallback(h))

Spec == Init /\ [][Next]_vars /\ WF_vars(Observe) /\ WF_vars(Tick)
             /\ WF_vars(Deliver) /\ WF_vars(Complete) /\ WF_vars(Destroy)

TypeOK == /\ op \in 0..MaxOps /\ age \in 0..MaxAge /\ discarded \in 0..MaxBytes
          /\ http \in {"none", "open", "eof", "aborted"}
          /\ mode \in {"idle", "forward", "drain", "done"}
          /\ \A b \in {coreAlive, coreActive, consumed, firstWire, firstText, result,
                        closing, canceled, failed, prematureAbort, badCoreCall,
                        foreignMutation} : b \in BOOLEAN
PolicyOracle == PrintT(<<"POLICY", coreAlive, coreActive, consumed, http, closing,
                         canceled, failed, age, discarded, Policy>>)
NoPrematureAbort == ~prematureAbort
NoNativeCallsAfterDestroy == ~badCoreCall
NoForeignHandleMutation == ~foreignMutation
NoDeadCoreConsumer == ~coreActive \/ coreAlive
CancelWins == canceled => ~coreActive
DrainRequiresSuccess == mode = "drain" => consumed
CleanupProgress == (consumed /\ http = "open") ~> (http # "open")
CancelProgress == (canceled /\ http = "open") ~> (http # "open")
CloseProgress == closing ~> ~coreAlive
TextProgress == (firstWire /\ coreActive) ~> (firstText \/ canceled \/ failed)
=============================================================================

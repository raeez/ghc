/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 2009
 *
 * User-space dtrace probes for the runtime system.
 *
 * ---------------------------------------------------------------------------*/

#include "HsFFI.h"
#include "rts/EventLogFormat.h"


/* -----------------------------------------------------------------------------
 * Payload datatypes for Haskell events
 * -----------------------------------------------------------------------------
 */

/* We effectively have:
 *
 * typedef uint16_t EventTypeNum;
 * typedef uint64_t EventTimestamp;   // in nanoseconds
 * typedef uint32_t EventThreadID;
 * typedef uint16_t EventCapNo;
 * typedef uint16_t EventPayloadSize; // variable-size events
 * typedef uint16_t EventThreadStatus;
 * typedef uint32_t EventCapsetID;
 * typedef uint16_t EventCapsetType;  // types for EVENT_CAPSET_CREATE
 */

/* -----------------------------------------------------------------------------
 * The HaskellEvent provider captures everything from eventlog for use with
 * dtrace
 * -----------------------------------------------------------------------------
 */

/* These probes correspond to the events defined in EventLogFormat.h
 */
provider HaskellEvent {

  /* scheduler events */
  probe create__thread (EventCapNo, EventThreadID);
  probe run__thread (EventCapNo, EventThreadID);
  probe stop__thread (EventCapNo, EventThreadID, EventThreadStatus, EventThreadID);
  probe thread__runnable (EventCapNo, EventThreadID);
  probe migrate__thread (EventCapNo, EventThreadID, EventCapNo);
  probe shutdown (EventCapNo);
  probe thread_wakeup (EventCapNo, EventThreadID, EventCapNo);
  probe gc__start (EventCapNo);
  probe gc__end (EventCapNo);
  probe request__seq__gc (EventCapNo);
  probe request__par__gc (EventCapNo);
  probe create__spark__thread (EventCapNo, EventThreadID);

  /* other events */
/* This one doesn't seem to be used at all at the moment: */
/*  probe log__msg (char *); */
  probe startup (EventCapNo);
  /* we don't need EVENT_BLOCK_MARKER with dtrace */
  probe user__msg (EventCapNo, char *);
  probe gc__idle (EventCapNo);
  probe gc__work (EventCapNo);
  probe gc__done (EventCapNo);
  probe capset__create(EventCapsetID, EventCapsetType);
  probe capset__delete(EventCapsetID);
  probe capset__assign__cap(EventCapsetID, EventCapNo);
  probe capset__remove__cap(EventCapsetID, EventCapNo);

  probe spark__counters(EventCapNo,
                        StgWord, StgWord, StgWord,
                        StgWord, StgWord, StgWord,
                        StgWord);

  probe spark__create   (EventCapNo);
  probe spark__dud      (EventCapNo);
  probe spark__overflow (EventCapNo);
  probe spark__run      (EventCapNo);
  probe spark__steal    (EventCapNo, EventCapNo);
  probe spark__fizzle   (EventCapNo);
  probe spark__gc       (EventCapNo);
};

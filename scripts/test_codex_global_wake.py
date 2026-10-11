import unittest
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]/"dot_local/share/codex-global-wake"))
import threading
from unittest.mock import patch
from wake_runtime import WakeState, Activity, instruction, meter, TerminalMeter, Rpc

class Tests(unittest.TestCase):
    def test_realtime_identity_is_thread_scoped_and_reset_between_wakes(self):
        a=Activity('ours')
        a.event({'method':'thread/realtime/started','params':{'threadId':'other','realtimeSessionId':'foreign'}})
        self.assertIsNone(a.state.session_id)
        a.state.mode='wake'
        a.event({'method':'thread/realtime/started','params':{'threadId':'ours','realtimeSessionId':'current'}})
        self.assertEqual(a.state.session_id,'current')
        a.event({'method':'thread/realtime/error','params':{'threadId':'ours'}})
        self.assertFalse(a.state.can_sleep(1e10))
        a.reset()
        self.assertIsNone(a.state.session_id)

    def test_unknown_never_sleeps(self):
        s=WakeState();s.mode='wake';s.last_input=0
        self.assertFalse(s.can_sleep(100))
    def test_manual_never_sleeps(self):
        s=WakeState();s.mode='manual';s.healthy=True;s.last_input=0
        self.assertFalse(s.can_sleep(100))
    def test_pending_holds_timeout(self):
        s=WakeState();s.mode='wake';s.healthy=True;s.last_input=0
        for attr in ('pending','turns','items'):
            getattr(s,attr).add('one');self.assertFalse(s.can_sleep(100));getattr(s,attr).clear()
        s.playing=1;self.assertFalse(s.can_sleep(100))
        s.playing=0;self.assertTrue(s.can_sleep(100))
    def test_overlapping_turns_and_foreign_completion(self):
        a=Activity('ours');a.state.mode='wake';a.state.healthy=True
        def e(method,tid,thread='ours'):
            a.event({'method':method,'params':{'threadId':thread,'turn':{'id':tid}}})
        e('turn/started','a');e('turn/started','b');e('turn/completed','a')
        self.assertFalse(a.state.can_sleep(1e10))
        e('turn/completed','b','other');self.assertFalse(a.state.can_sleep(1e10))
        e('turn/completed','b');self.assertTrue(a.state.can_sleep(1e10))
    def test_started_speech_blocks_until_complete(self):
        a=Activity('ours');a.state.mode='wake';a.state.healthy=True
        item={'id':'answer','type':'transcriptSegment','role':'assistant'}
        a.event({'method':'thread/realtime/item/started','params':{'threadId':'ours','item':item}})
        self.assertFalse(a.state.can_sleep(1e10))
        a.event({'method':'thread/realtime/item/completed','params':{'threadId':'ours','item':item}})
        self.assertTrue(a.state.can_sleep(1e10))
    def test_previous_realtime_session_cannot_clear_new_speech(self):
        a=Activity('ours');a.state.mode='wake';a.state.healthy=True
        a.event({'method':'thread/realtime/started','params':{'threadId':'ours','realtimeSessionId':'new'}})
        current={'id':'answer','type':'transcriptSegment','role':'assistant','realtimeSessionId':'new'}
        old={**current,'realtimeSessionId':'old'}
        a.event({'method':'thread/realtime/item/started','params':{'threadId':'ours','item':current}})
        a.event({'method':'thread/realtime/item/completed','params':{'threadId':'ours','item':old}})
        self.assertFalse(a.state.can_sleep(1e10))
    def test_queued_delegation_blocks_sleep_until_work_finishes(self):
        a=Activity('ours');a.state.mode='wake';a.state.healthy=True
        item={'id':'job','type':'bemItemPromoted','turnId':'long-work'}
        a.event({'method':'thread/realtime/item/added','params':{'threadId':'ours','item':item}})
        self.assertFalse(a.state.can_sleep(1e10))
        a.event({'method':'turn/completed','params':{'threadId':'ours','turn':{'id':'long-work'}}})
        self.assertFalse(a.state.can_sleep(a.state.last_input+14.99))
        self.assertTrue(a.state.can_sleep(a.state.last_input+15))
        # Late promotion must not resurrect an already completed job.
        a.event({'method':'thread/realtime/item/added','params':{'threadId':'ours','item':item}})
        self.assertTrue(a.state.can_sleep(a.state.last_input+15))
    def test_existing_work_survives_off_and_next_wake(self):
        a=Activity('ours')
        a.event({'method':'turn/started','params':{'threadId':'ours','turn':{'id':'ongoing'}}})
        a.reset();a.state.mode='wake';a.state.healthy=True
        self.assertFalse(a.state.can_sleep(1e10))
        a.event({'method':'turn/completed','params':{'threadId':'ours','turn':{'id':'ongoing'}}})
        self.assertFalse(a.state.can_sleep(a.state.last_input+14.99))
        self.assertTrue(a.state.can_sleep(a.state.last_input+15))
    def test_prefix_only_bounded_and_preserves_structured_text(self):
        self.assertEqual(instruction('Hey Codex, !do not run this'), '!do not run this')
        self.assertEqual(instruction('Hey codecs. Tell me the weather.'),'Tell me the weather.')
        self.assertEqual(instruction('HeyCodex, ask me about my day'),'ask me about my day')
        self.assertEqual(instruction('Hay Codex, ask me about my day'),'ask me about my day')
        self.assertIsNone(instruction('Hey Cortex, ask me about my day'))
        for value in (None, {}, 'x'*9000, 'someone says hey codex', 'hey coder'):
            self.assertIsNone(instruction(value))
    def test_meter_fails_closed_and_uses_latest(self):
        self.assertIsNone(meter('other output'))
        self.assertEqual(meter('mic ▁▁▁  codex ▁█▁'),(False,True))
        self.assertEqual(meter('mic ███ codex ▁▁▁ mic ▁▁▁ codex ▁▁▁'),(False,False))
    def test_incremental_terminal_update_clears_speaker_meter(self):
        reader=TerminalMeter()
        reader.feed(b'\x1b[2J\x1b[1;1H')
        self.assertEqual(reader.feed('mic ▁▁▁  codex ███'.encode()), (False,True))
        # Codex updates only the changed cells, rather than printing a full footer.
        self.assertEqual(reader.feed(('\x1b[1;16H'+'▁▁▁').encode()), (False,False))
    def test_ambiguous_rpc_timeout_is_not_retried(self):
        class Socket:
            messages=[]
            def send(self,message): self.messages.append(message)
        rpc=Rpc.__new__(Rpc);rpc.socket=Socket();rpc.write_lock=threading.Lock()
        rpc.counter=0;rpc.pending={}
        with self.assertRaises(TimeoutError):rpc.call('test',{},timeout=.01)
        self.assertEqual(len(rpc.socket.messages),1)
        self.assertEqual(rpc.pending,{})
    def test_15_second_boundary(self):
        s=WakeState();s.mode='wake';s.healthy=True;s.last_input=2
        self.assertFalse(s.can_sleep(16.999));self.assertTrue(s.can_sleep(17))

if __name__=='__main__':unittest.main()

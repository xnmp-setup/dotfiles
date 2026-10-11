import unittest
import threading
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]/"dot_local/share/codex-global-wake"))
from wake_runtime import WakeReply, Activity

class ReplyTests(unittest.TestCase):
    def final(self, reply, text='How is your day going?', turn='ours', item='answer', phase='final_answer'):
        reply.event('item/completed', {'turnId':turn,'item':{'type':'agentMessage','id':item,'text':text,'phase':phase}})
    def done(self, reply, turn='ours'):
        reply.event('turn/completed', {'turn':{'id':turn}})
    def test_completed_before_start_ack_and_voice_ready_is_delivered_once(self):
        r=WakeReply();self.final(r);self.done(r)
        self.assertIsNone(r.take())
        r.bind('ours');self.assertIsNone(r.take())
        r.ready=True;self.assertEqual(r.take(),'How is your day going?')
        self.final(r);self.done(r);self.assertIsNone(r.take())
    def test_reply_after_voice_ready_waits_for_work_completion(self):
        r=WakeReply();r.bind('ours');r.ready=True
        self.final(r);self.assertIsNone(r.take())
        self.done(r);self.assertEqual(r.take(),'How is your day going?')
    def test_foreign_turn_and_private_output_are_not_voiced(self):
        r=WakeReply();r.bind('ours');r.ready=True
        self.final(r,'foreign',turn='other');self.done(r,'other')
        self.final(r,'private',phase='commentary')
        self.final(r,'[ANALYSIS] private',phase=None)
        self.done(r);self.assertIsNone(r.take())
        self.final(r,'visible');self.assertEqual(r.take(),'visible')
    def test_duplicate_items_and_oversized_results_are_bounded(self):
        r=WakeReply();r.bind('ours');r.ready=True
        self.final(r,'x'*100000);self.final(r,'x'*100000);self.done(r)
        self.assertEqual(r.take(),'x'*4096)
    def test_ambiguous_speech_submission_is_attempted_once_and_keeps_voice_awake(self):
        a=Activity('thread');a.state.mode='wake';a.state.healthy=True
        a.reply=WakeReply();a.reply.bind('ours');a.reply.ready=True
        self.final(a.reply);self.done(a.reply);a.state.pending.add('delivery')
        stop=threading.Event();calls=[]
        class Rpc:
            closed=False
            def call(self, method, params):
                calls.append((method,params));stop.set()
                raise TimeoutError('accepted or lost acknowledgement')
        a.delivery_changed.set();a.deliver(Rpc(),stop)
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][0],'thread/realtime/appendSpeech')
        self.assertEqual(calls[0][1]['threadId'],'thread')
        self.assertIn('How is your day going?',calls[0][1]['text'])
        self.assertIsNone(a.take_speech())
        self.assertFalse(a.state.can_sleep(1e10))

    def test_manual_off_cancels_buffer_without_forgetting_work(self):
        a=Activity('thread');a.state.mode='wake';a.reply=WakeReply();a.reply.bind('ours')
        a.active_turns.add('ours');self.final(a.reply);a.reset()
        self.assertIsNone(a.take_speech());self.assertIn('ours',a.active_turns)
    def test_buffer_and_queued_speech_prevent_idle_sleep(self):
        a=Activity('thread');a.state.mode='wake';a.state.healthy=True
        a.reply=WakeReply();a.reply.bind('ours');a.state.pending.add('delivery')
        self.final(a.reply);self.done(a.reply)
        self.assertFalse(a.state.can_sleep(1e10));self.assertIsNone(a.take_speech())
        a.reply.ready=True;self.assertEqual(a.take_speech(),'How is your day going?')
        self.assertFalse(a.state.can_sleep(1e10))
        a.event({'method':'thread/realtime/item/started','params':{'threadId':'thread','item':{'id':'speech','type':'transcriptSegment','role':'assistant'}}})
        self.assertFalse(a.state.can_sleep(1e10))
        a.event({'method':'thread/realtime/item/completed','params':{'threadId':'thread','item':{'id':'speech','type':'transcriptSegment','role':'assistant'}}})
        self.assertFalse(a.state.can_sleep(a.state.last_input+14.9))
        self.assertTrue(a.state.can_sleep(a.state.last_input+15))

if __name__=='__main__':unittest.main()

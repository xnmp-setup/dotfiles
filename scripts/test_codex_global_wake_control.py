import importlib.machinery, importlib.util
import json, os, socket, tempfile, threading, time, unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0,str(Path(__file__).parents[1]/"dot_local/share/codex-global-wake"))
from wake_runtime import Activity, WakeState, WakeReply, meter
from queue import Queue
loader=importlib.machinery.SourceFileLoader('voice_control',str(Path(__file__).parents[1]/"dot_local/bin/executable_codex-global-voice"))
spec=importlib.util.spec_from_loader(loader.name,loader);v=importlib.util.module_from_spec(spec);loader.exec_module(v)

class Process:
    pid=123
    alive=True
    def poll(self):return None if self.alive else 0
    def terminate(self):self.alive=False
    def wait(self,*_):self.alive=False

class Terminal:
    instance=None
    def __init__(self,*args,**kwargs):
        Terminal.instance=self;self.process=Process();self.condition=threading.Condition()
        self.ready=True;self.cancelled=threading.Event();self.on=False
        self.meter_state=None;self.meter_time=0;self.text=''
    def voice_active(self):return self.on
    def toggle(self):
        desired=not self.on
        if desired:
            tid=next(p['threadId'] for m,p in Rpc.instance.calls if m=='thread/resume')
            Rpc.instance.events.put({'method':'thread/realtime/started','params':{'threadId':tid,'realtimeSessionId':'test'}})
        self.on=desired
        return {'voice':'on' if self.on else 'off','pid':self.process.pid}
    def refresh_meter(self):pass
    def close(self):self.process.terminate()

class Rpc:
    instance=None
    def __init__(self,*_):Rpc.instance=self;self.calls=[];self.events=Queue();self.closed=False
    def call(self,method,params):
        self.calls.append((method,params))
        if method=='turn/start': self.submitted_before_capture=not Terminal.instance.on
        return {'turn': {'id': 'work-1'}} if method == 'turn/start' else {}
    def close(self):self.closed=True

class Test(unittest.TestCase):
    def test_wake_handoff_single_scoped_rpc_and_manual_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);control=root/'control.sock';state=root/'thread-id'
            tid='01a1246f-333c-7ce0-a295-390b325296d8';state.write_text(tid)
            def server(*args,**kwargs):
                (root/'app-server.sock').touch();return Process()
            errors=[]
            def run():
                try:v.serve()
                except Exception as e:errors.append(e)
            with patch.object(v,'WAKE_ENABLED',True),patch.object(v,'Rpc',Rpc,create=True),patch.object(v,'Activity',Activity,create=True),patch.object(v,'WakeState',WakeState,create=True),patch.object(v,'WakeReply',WakeReply,create=True),patch.object(v,'paths',return_value=(control,state)),patch.object(v,'persona_arguments',return_value=[]),patch.object(v,'codex_binary',return_value='/bin/true'),patch.object(v,'NativeTerminal',Terminal),patch.object(v.subprocess,'Popen',side_effect=server),patch.object(v.signal,'signal'):
                t=threading.Thread(target=run);t.start()
                try:
                    end=time.monotonic()+3
                    while not control.exists() and time.monotonic()<end:time.sleep(.01)
                    def send(msg):
                        with socket.socket(socket.AF_UNIX) as s:
                            s.connect(str(control));s.sendall((json.dumps(msg) if isinstance(msg,dict) else msg).encode()+b'\n');return json.loads(s.recv(65536))
                    self.assertTrue(send('status')['wakeReady'])
                    self.assertTrue(send({'command':'wake','text':'!Please say hello'})['accepted'])
                    self.assertFalse(send({'command':'wake','text':'duplicate'})['accepted'])
                    calls=[x for x in Rpc.instance.calls if x[0]=='turn/start']
                    self.assertEqual(len(calls),1)
                    self.assertTrue(Rpc.instance.submitted_before_capture)
                    self.assertEqual(calls[0][1]['threadId'],tid)
                    self.assertEqual(calls[0][1]['effort'],'medium')
                    self.assertEqual(calls[0][1]['input'][0]['text'],'!Please say hello')
                    self.assertEqual(calls[0][1]['input'][0]['text_elements'],[])
                    contexts=[p for m,p in Rpc.instance.calls if m=='thread/realtime/appendText']
                    self.assertEqual(contexts,[{'threadId':tid,'role':'user','text':'[USER] !Please say hello'}])
                    self.assertEqual(send('status')['wakeState']['turns'],1)
                    self.assertEqual(send('status')['origin'],'wake')
                    self.assertEqual(send('toggle')['voice'],'off')
                    self.assertEqual(send('toggle')['voice'],'on')
                    self.assertEqual(send('status')['origin'],'manual')
                    self.assertIn('error',send({'command':'wake','text':None}))
                finally:
                    Terminal.instance.process.terminate();t.join(3)
                self.assertFalse(t.is_alive());self.assertEqual(errors,[])

if __name__=='__main__':unittest.main()

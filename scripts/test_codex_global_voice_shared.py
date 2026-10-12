"""Actual shared-pane outcomes: readable output, one owner, safe viewer detach."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
import uuid

ROOT = Path(__file__).parents[1]
LIB = ROOT/'dot_local/share/codex-global-voice'
sys.path.insert(0,str(LIB))
from shared_terminal import SharedTerminal, PaneProcess, process_identity

PROGRAM = '''import os,tty,sys
from pathlib import Path
tty.setraw(0)
p=Path(sys.argv[1]);p.write_text('off')
os.write(1,b'REPORT BEGIN\\r\\n')
for i in range(200):os.write(1,('Report line '+str(i)+'\\r\\n').encode())
os.write(1,b'REPORT END\\r\\nREPORT: a complete readable result\\r\\nContext 0% used\\r\\n')
while True:
 data=os.read(0,1024)
 if b'\\x1b[19~' in data:
  p.write_text('off' if p.read_text()=='on' else 'on')
  os.write(1,b'\\r\\nVoice toggled\\r\\n')
'''

class SharedTests(unittest.TestCase):
    def test_reused_pid_is_not_a_live_native_owner(self):
        self.assertIsNone(PaneProcess({'pid':os.getpid(),'start':process_identity(os.getpid())}).poll())
        self.assertEqual(PaneProcess({'pid':os.getpid(),'start':'stale'}).poll(),0)

    @unittest.skipUnless(shutil.which('zellij'),'Zellij is required for the shared-terminal integration test')
    def test_read_report_and_detach_while_same_native_session_stays_on(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);flag=root/'capture';thread=str(uuid.uuid4())
            options={'config':ROOT/'dot_config/codex-global-voice/zellij.kdl',
                     'runner':LIB/'session_runner.py'}
            capture=lambda _:flag.read_text()=='on'
            terminal=SharedTerminal([sys.executable,'-u','-c',PROGRAM,str(flag)],root,thread,capture,**options)
            client=None;master=None
            try:
                deadline=time.monotonic()+10
                while not terminal.ready:
                    self.assertLess(time.monotonic(),deadline);time.sleep(.05)
                self.assertIn('complete readable result',terminal.text)
                self.assertIn('REPORT BEGIN',terminal.text)
                self.assertIn('REPORT END',terminal.text)
                first=terminal.toggle();self.assertEqual(first['voice'],'on')
                reused=SharedTerminal([],root,thread,capture,**options)
                self.assertEqual(reused.process.pid,first['pid'])
                master,slave=pty.openpty()
                fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,120,0,0))
                client=subprocess.Popen(['zellij','--config',str(options['config']),'attach',terminal.session],
                    stdin=slave,stdout=slave,stderr=slave,
                    env={**os.environ,'TERM':'xterm-256color'},start_new_session=True)
                os.close(slave)
                data=b'';deadline=time.monotonic()+10
                while b'complete readable result' not in data and time.monotonic()<deadline:
                    if select.select([master],[],[],.2)[0]:data+=os.read(master,65536)
                self.assertIn(b'complete readable result',data)
                terminal.run(['action','scroll-to-top'])
                top=b'';deadline=time.monotonic()+5
                while b'REPORT BEGIN' not in top and time.monotonic()<deadline:
                    if select.select([master],[],[],.2)[0]:top+=os.read(master,65536)
                self.assertIn(b'REPORT BEGIN',top)
                terminal.run(['action','scroll-to-bottom'])
                panes=json.loads(terminal.run(['action','list-panes','--json']).stdout)
                self.assertFalse(any(p.get('is_floating') and p.get('plugin_url') in ('about','zellij:about') for p in panes))
                self.assertIsNone(terminal.process.poll())
                self.assertEqual(flag.read_text(),'on')
                client.terminate();client.wait(5);client=None
                self.assertIsNone(terminal.process.poll())
                self.assertEqual(flag.read_text(),'on')
                last=terminal.toggle();self.assertEqual(last['voice'],'off')
                self.assertEqual(last['pid'],first['pid'])
                # A session whose native identity is missing must never cause
                # a second process to be launched against the same conversation.
                terminal.record.unlink()
                with self.assertRaises(RuntimeError):
                    SharedTerminal([],root,thread,capture,**options)
                self.assertIsNone(terminal.process.poll())
            finally:
                if client:client.terminate();client.wait(5)
                if master is not None:os.close(master)
                terminal.close()

if __name__=='__main__':unittest.main()

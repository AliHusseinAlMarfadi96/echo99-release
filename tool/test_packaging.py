import json, pathlib, struct, subprocess, tempfile, unittest
SCRIPT=pathlib.Path(__file__).with_name('package_adhoc_ipa.sh')
CODE=SCRIPT.read_text().split("<< 'PY'\n",1)[1].split('\nPY\n',1)[0]
class Packaging(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name)/'Runner.app';self.root.mkdir();self.frameworks=self.root/'Frameworks';self.frameworks.mkdir();self.manifest=self.root/'NativeAssetsManifest.json';self.manifest.write_text(json.dumps({'native-assets':{'ios_arm64':{'package:objective_c/objective_c.dylib':['absolute','objective_c.framework/objective_c']}}}))
 def tearDown(self):self.temp.cleanup()
 def run_script(self):
  p=pathlib.Path(self.temp.name)/'check.py';p.write_text(CODE);return subprocess.run(['python3',str(p),str(self.root)],capture_output=True,text=True)
 def test_missing_ffi_fails(self):
  r=self.run_script();self.assertNotEqual(r.returncode,0);self.assertIn('Missing required native asset',r.stderr)
 def test_unlinked_ffi_and_other_frameworks_survive(self):
  for name in ['objective_c','OtherFFI']:
   p=self.frameworks/(name+'.framework');p.mkdir();(p/name).write_bytes(b'FFI fixture')
  self.manifest.write_text(json.dumps({'native-assets':{'ios_arm64':{'objc':['absolute','objective_c.framework/objective_c'],'other':['absolute','OtherFFI.framework/OtherFFI']}}}));r=self.run_script();self.assertEqual(r.returncode,0,r.stderr);self.assertTrue((self.frameworks/'objective_c.framework/objective_c').exists());self.assertTrue((self.frameworks/'OtherFFI.framework/OtherFFI').exists())
 def test_unsafe_manifest_fails(self):
  self.manifest.write_text(json.dumps({'native-assets':{'ios_arm64':{'bad':['absolute','../bad']}}}));self.assertIn('Unsafe native asset path',self.run_script().stderr)
 def test_dependency_closure_keeps_ffi_dependency_removes_unloaded_100(self):
  def macho(path,version,deps=()):
   cmds=[struct.pack('<IIIIII',0x32,24,2,version,version,0)]
   for dep in deps:
    name=dep.encode()+b'\0';size=(24+len(name)+7)//8*8
    cmds.append(struct.pack('<IIIIII',0xC,size,24,0,0,0)+name+b'\0'*(size-24-len(name)))
   body=b''.join(cmds);path.parent.mkdir(parents=True,exist_ok=True)
   path.write_bytes(struct.pack('<IIIIIIII',0xfeedfacf,0x100000c,0,6,len(cmds),len(body),0,0)+body)
  macho(self.frameworks/'objective_c.framework/objective_c',15<<16,['@rpath/FFIDep.framework/FFIDep'])
  macho(self.frameworks/'FFIDep.framework/FFIDep',15<<16)
  macho(self.frameworks/'UnusedPod.framework/UnusedPod',100<<16)
  r=self.run_script();self.assertEqual(r.returncode,0,r.stderr)
  self.assertTrue((self.frameworks/'FFIDep.framework/FFIDep').exists())
  self.assertFalse((self.frameworks/'UnusedPod.framework').exists())
  self.assertIn('minimum iOS 15.0',r.stdout)
if __name__=='__main__':unittest.main()

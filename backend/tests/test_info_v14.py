import importlib.util
import sys
import unittest
from pathlib import Path
SRC=Path(__file__).resolve().parents[1]/'scripts'/'publish_course_packages.py'
spec=importlib.util.spec_from_file_location('publisher_v14',SRC)
publisher=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=publisher
spec.loader.exec_module(publisher)
class InfoTests(unittest.TestCase):
    def test_valid_info(self):
        ids=set()
        publisher.validate_exercise({'type':'info','id':'q50','instruction':'Cultura','prompt':'Caffè','explanation':'O café italiano',
          'category':'culture','image':{'url':'https://images.example.org/cafe.jpg','alt':'Café','caption':'Espresso'}},ids)
        self.assertEqual(ids,{'q50'})
    def test_invalid_images_and_unknown_fields(self):
        for url in ['http://bad.com/x.png','https://localhost/a','https://127.0.0.1/a','file:///foo','https://john:password@a.com/image']:
            with self.assertRaises(publisher.PublicationError):publisher.validate_exercise({'type':'info','id':'q55','instruction':'Info','prompt':'Olá','explanation':'Corpo',
            'image':{'url':url,'alt':'Teste'}},set())
        with self.assertRaises(publisher.PublicationError):publisher.validate_exercise({'type':'info','id':'q55','instruction':'Info','prompt':'Olá','explanation':'Corpo','html':'<script>'},set())
if __name__=='__main__':unittest.main()

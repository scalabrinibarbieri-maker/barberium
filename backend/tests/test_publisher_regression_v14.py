import importlib.util
import json
import sys
import unittest
import zipfile
from pathlib import Path
from tempfile import TemporaryDirectory
SRC=Path(__file__).resolve().parents[1]/'scripts'/'publish_course_packages.py'
spec=importlib.util.spec_from_file_location('publish_course_v14',SRC)
publisher=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=publisher
spec.loader.exec_module(publisher)
class RegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp=TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.summary={'id':'it-a1-u02','language':'it','level':'A1','order':2,'title':'Conhecendo pessoas','subtitle':'Apresentações','revision':1,
                      'lessons':[{'id':'it-a1-04','title':'Apresente-se','subtitle':'Nomes','exerciseCount':2}]}
        self.ex1={'id':'q19','type':'choice','prompt':'Ciao','instruction':'Escolha','explanation':'Saudação',
                  'options':[{'id':'a','label':'Olá'},{'id':'b','label':'Não'}],'correctOptionId':'a'}
        self.ex2={'id':'q20','type':'write','prompt':'Obrigado','instruction':'Escreva','explanation':'É grazie',
                  'acceptedAnswers':['grazie'],'sampleAnswer':'Grazie'}
        self.unit={'version':1,'unitId':'it-a1-u02','revision':1,'lessons':[{
            'id':'it-a1-04','title':'Apresente-se','subtitle':'Nomes','unit':2,'exercises':[self.ex1,self.ex2]}]}
    def make_zip(self,*,extra=None,summary=None,unit=None):
        path=Path(self.temp.name)/'curso-lunivo-unidade-teste.zip'
        s=summary or self.summary;u=unit or self.unit
        with zipfile.ZipFile(path,'w') as z:
            z.writestr('catalog-part.json',json.dumps({'version':1,'units':[s]}))
            z.writestr(publisher.file_key(s),json.dumps(u))
            if extra:z.writestr(extra,b'bad')
        return path
    def test_valid_package(self):
        rows=publisher.read_package(self.make_zip())
        self.assertEqual(rows[0][0]['id'],'it-a1-u02')
        self.assertEqual(json.loads(rows[0][1])['lessons'][0]['exercises'][0]['id'],'q19')
    def test_reject_extra_file(self):
        with self.assertRaises(publisher.PublicationError):publisher.read_package(self.make_zip(extra='../attack'))
    def test_reject_builtin_lesson_id(self):
        s={**self.summary,'lessons':[{'id':'it-a1-03','title':'Apresente-se','subtitle':'Nomes','exerciseCount':2}]}
        with self.assertRaises(publisher.PublicationError):publisher.read_package(self.make_zip(summary=s))
    def test_reject_reserved_exercise(self):
        u={**self.unit,'lessons':[{**self.unit['lessons'][0],'exercises':[{**self.ex1,'id':'q03'},self.ex2]}]}
        with self.assertRaises(publisher.PublicationError):publisher.read_package(self.make_zip(unit=u))
    def test_reject_duplicate_exercise_ids(self):
        u={**self.unit,'lessons':[{**self.unit['lessons'][0],'exercises':[self.ex1,{**self.ex2,'id':'q19'}]}]}
        with self.assertRaises(publisher.PublicationError):publisher.read_package(self.make_zip(unit=u))
    def test_reject_bad_correct_choice(self):
        u={**self.unit,'lessons':[{**self.unit['lessons'][0],'exercises':[{**self.ex1,'correctOptionId':'z'},self.ex2]}]}
        with self.assertRaises(publisher.PublicationError):publisher.read_package(self.make_zip(unit=u))
    def test_merge_adds_new_unit_and_keeps_existing(self):
        earlier={**self.summary,'id':'it-a1-u03','order':3,'lessons':[{'id':'it-a1-06','title':'Outras palavras','subtitle':'Algo','exerciseCount':2}]}
        merged=publisher.merge_catalog([earlier],[self.summary])
        self.assertEqual(len(merged),2);self.assertEqual(merged[0]['id'],'it-a1-u02')
    def test_reject_revision_rewrite(self):
        s={**self.summary,'title':'Outro título'}
        with self.assertRaises(publisher.PublicationError):publisher.merge_catalog([self.summary],[s])
    def test_higher_revision_accepted(self):
        s={**self.summary,'revision':2}
        self.assertEqual(publisher.merge_catalog([self.summary],[s])[0]['revision'],2)
    def test_catalog_does_not_duplicate_lesson(self):
        s={**self.summary,'id':'it-a1-u03','order':3}
        with self.assertRaises(publisher.PublicationError):publisher.merge_catalog([self.summary],[s])
    def test_merge_reject_duplicate_unit(self):
        with self.assertRaises(publisher.PublicationError):publisher.parse_catalog({'version':1,'units':[self.summary,self.summary]},partial=True)
if __name__=='__main__':unittest.main()

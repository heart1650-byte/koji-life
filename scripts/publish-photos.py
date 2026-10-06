"""Publish owner-approved submissions with re-encoded user photos; AI requests remain pending."""
from pathlib import Path
from PIL import Image, ImageOps
import base64, io, hashlib, json, subprocess
root=Path(__file__).resolve().parents[1]
community=json.loads((root/'community-recipes.json').read_text())
for path in sorted((root/'submissions').glob('*.json')):
 if path.stat().st_size>800000: raise ValueError('Submission is too large: '+path.name)
 data=json.loads(path.read_text())
 check=subprocess.run(['node','-e',"const C=require('./recipe-core.js');const d=JSON.parse(require('fs').readFileSync(0,'utf8'));const e=C.validateSubmission(d);if(e.length){console.error(e.join('; '));process.exit(1)}"],cwd=root,input=json.dumps(data),text=True,capture_output=True)
 if check.returncode: raise ValueError(path.name+': '+check.stderr)
 if data.get('imageMode')!='photo':continue
 photo=data.get('photoData','')
 if not isinstance(photo,str) or not photo.startswith('data:image/webp;base64,') or len(photo)>700000:raise ValueError('Invalid photo: '+path.name)
 raw=base64.b64decode(photo.split(',',1)[1],validate=True)
 if raw[:4]!=b'RIFF' or raw[8:12]!=b'WEBP':raise ValueError('Not a WebP photo')
 Image.MAX_IMAGE_PIXELS=10000000
 with Image.open(io.BytesIO(raw)) as im:
  im=ImageOps.exif_transpose(im).convert('RGB');im.thumbnail((960,960))
  key=hashlib.sha256(path.name.encode()).hexdigest()[:12];image='assets/recipes/community-'+key+'.webp';im.save(root/image,'WEBP',quality=80,exif=b'')
 recipe={k:data[k] for k in ['title','author','desc','type','koji','base','servingUnit','ing','steps']}
 recipe.update(id=int(key,16),serving=str(data['base'])+data['servingUnit'],image=image,imageKind='photo',submissionFile=path.name)
 community=[x for x in community if x.get('submissionFile')!=path.name];community.append(recipe)
(root/'community-recipes.json').write_text(json.dumps(community,ensure_ascii=False,indent=2)+'\n')
print('Published photo submissions:',len(community))

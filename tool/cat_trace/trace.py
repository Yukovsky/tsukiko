"""Trace the drawn cat sheets into vector layers (body without head).

Output per sheet and pose: head anchor (eye midpoint, tilt), layers of
closed contours per tone class, tail weights per point, a resampled body
outline for morphing. Units: the generated head's half width (rx); origin
on the floor under the figure.
"""
import json, sys, numpy as np, cv2
from extract import cells, silhouette, R
E=json.load(open('eyes.json')); H=json.load(open('head.json'))
CLASSES=['shade','deep','light','ink']
# The generated head is drawn this much bigger than the eyes alone would
# put it; the drawn head is cut out a little wider still.
HEAD=1.1; HK=1.15
TAILS={(1,0):((395,340),(460,235),.5),(1,1):((390,330),(450,225),.5),(1,5):((390,178),(455,80),.5),
       (2,0):((385,365),(425,265),.45),(2,1):((375,360),(420,255),.45),(2,5):((395,192),(440,100),.45),
       (3,0):((360,360),(430,250),.75),(3,1):((370,350),(420,225),.75),(3,5):((380,170),(440,65),.75)}
def classify(crop, body):
    L=crop.mean(axis=2)
    base=np.median(L[(body>0)&(L>np.percentile(L[body>0],40))&(L<np.percentile(L[body>0],85))])
    r=L/base
    lab=np.full(L.shape,0,np.uint8)  # 0 base
    lab[r<0.95]=1   # shade
    lab[r<0.82]=2   # deep
    lab[r<0.66]=4   # ink
    lab[(r>1.035)&(r<1.22)]=3  # light
    lab=cv2.medianBlur(lab,5)
    lab[body==0]=255
    return lab
def contours(mask, eps, minarea):
    cs,hier=cv2.findContours(mask,cv2.RETR_CCOMP,cv2.CHAIN_APPROX_NONE)
    out=[]
    if hier is None: return out
    for c,hh in zip(cs,hier[0]):
        if abs(cv2.contourArea(c))<minarea: continue
        a=cv2.approxPolyDP(c,eps,True)[:,0,:]
        if len(a)>=3: out.append(a)
    return out
def trace(i,name):
    img=cv2.cvtColor(cv2.imread(f'{R}/{['','tsukiko','lumi','yuko'][i]}.webp'),cv2.COLOR_BGR2RGB)
    poses=[]
    for k,box in enumerate(cells(img)):
        x0,y0,x1,y1=box
        m,c=silhouette(img,box)
        crop=img[y0:y1,x0:x1].astype(float)
        e=E[name][k]; s=e['scale']; mid=np.array(e['mid'])-[x0,y0]
        ang=e['ang'] if k==4 else 0.0
        ca,sa=np.cos(ang),np.sin(ang)
        hp=np.array([[mid[0]+s*HK*(x*ca-y*sa), mid[1]+s*HK*(x*sa+y*ca)] for x,y in H[name]['outline']]).astype(np.int32)
        headm=np.zeros_like(m); cv2.fillPoly(headm,[hp],255)
        body=m.copy(); body[headm>0]=0
        # Thin leftovers of the drawn ears next to the head are dropped.
        near=cv2.dilate(headm,np.ones((int(.35*s),int(.35*s)),np.uint8))
        rr=max(3,int(.09*s))
        op=cv2.morphologyEx(body,cv2.MORPH_OPEN,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(2*rr+1,2*rr+1)))
        body=np.where(near>0,op,body).astype(np.uint8)
        # plug: removed area below the eyes, filled with fur under the head
        plug=((m>0)&(headm>0)).astype(np.uint8)*255
        yy=np.arange(m.shape[0])[:,None]
        plug[:max(0,int(mid[1]+0.15*s))]=0
        n,lab_,st,_=cv2.connectedComponentsWithStats((body>0).astype(np.uint8))
        keep=1+np.argmax(st[1:,cv2.CC_STAT_AREA]); body=((lab_==keep)*255).astype(np.uint8)
        lab=classify(crop,body)
        ys,xs=np.nonzero(m); ox=(xs.min()+xs.max())/2; oy=ys.max()
        def norm(a): return [((x-ox)/s, (y-oy)/s) for x,y in a]
        # tail: marked by hand on the sheets (root, tip in cell pixels)
        tw=np.zeros(m.shape,np.float32); root=None
        spec=None
        if k in (0,1,5):
            ys_,xs_=np.nonzero(body)
            far=xs_>mid[0]+(1.5 if k==5 else 1.25)*s
            j=np.argmin(np.where(far,ys_,1e9)); tip=np.array([xs_[j],ys_[j]],float)
            rr2=int((0.62 if i==3 else 0.5)*s)
            thick=cv2.morphologyEx(body,cv2.MORPH_OPEN,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(2*rr2+1,2*rr2+1)))
            ty2,tx2=np.nonzero(thick)
            # the thick body point nearest the tip, not the tail's own bulb
            dd=np.hypot(tx2-tip[0],ty2-tip[1]); low=ty2>tip[1]+0.6*s
            j2=np.argmin(np.where(low,dd,1e9)); root=np.array([tx2[j2],ty2[j2]],float)
            spec=(root,tip,0.78 if i==3 else 0.55)
        if spec:
            root,tip,half=spec
            ax=tip-root; L=np.hypot(*ax); ax/=L; nrm=np.array([-ax[1],ax[0]])
            yy,xx=np.mgrid[0:m.shape[0],0:m.shape[1]]
            d=np.stack([xx-root[0],yy-root[1]],-1)
            t=(d@ax)/L; q=np.abs(d@nrm)
            reg=((body>0)&(t>-0.05)&(t<1.45)&(q<half*s)).astype(np.uint8)
            n,cl,st,_=cv2.connectedComponentsWithStats(reg)
            j=cl[int(tip[1]),int(tip[0])]
            if j>0:
                w=np.clip(t,0,1); w=w*w*(3-2*w)
                tw=np.where(cl==j,w,0).astype(np.float32)
                tw=cv2.GaussianBlur(cv2.dilate(tw,np.ones((7,7),np.uint8)),(13,13),0)
        def wt(a): return [float(tw[min(max(int(y),0),tw.shape[0]-1),min(max(int(x),0),tw.shape[1]-1)]) for x,y in a]
        layers={}
        outline=contours(body,0.8,50)
        layers['base']=[(norm(a),wt(a)) for a in outline]
        layers['plug']=[(norm(a),[0]*len(a)) for a in contours(plug,1.0,30)]
        for code,cl in [(1,'shade'),(2,'deep'),(3,'light'),(4,'ink')]:
            mk=((lab==code)*255).astype(np.uint8)
            mk[body==0]=0
            if cl=='ink': mk=cv2.dilate(mk,np.ones((2,2),np.uint8))
            cs=contours(mk,0.7 if cl=='ink' else 1.0,10 if cl=='ink' else 40)
            layers[cl]=[(norm(a),wt(a)) for a in cs]
        # morph outline: N points, from the floor-left, clockwise
        big=max(outline,key=lambda a:cv2.contourArea(a.reshape(-1,1,2)))
        dense=cv2.findContours(body,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_NONE)[0]
        dense=max(dense,key=cv2.contourArea)[:,0,:].astype(float)
        seg=np.hypot(*np.diff(np.vstack([dense,dense[:1]]),axis=0).T); cum=np.concatenate([[0],np.cumsum(seg)])
        start=np.argmin(dense[:,0]-3*dense[:,1]); 
        dense=np.roll(dense,-start,axis=0)
        seg=np.hypot(*np.diff(np.vstack([dense,dense[:1]]),axis=0).T); cum=np.concatenate([[0],np.cumsum(seg)])
        N=200; t=np.linspace(0,cum[-1],N,endpoint=False)
        rs=np.array([np.interp(t,cum,np.append(dense[:,0],dense[0,0])),np.interp(t,cum,np.append(dense[:,1],dense[0,1]))]).T
        poses.append({'head':[(mid[0]-ox)/s,(mid[1]-oy)/s,ang],
                      'layers':{k2:[{'p':p,'w':w} for p,w in v] for k2,v in layers.items()},
                      'morph':norm(rs),'morphW':wt(rs),
                      'root':None if root is None else [(root[0]-ox)/s,(root[1]-oy)/s],
                      'size':[(xs.max()-xs.min())/s,(oy-ys.min())/s]})
        # preview
        vis=np.full((m.shape[0],m.shape[1],3),240,np.uint8)
        col={'base':(150,150,215),'shade':(120,120,190),'deep':(90,90,160),'light':(185,185,235),'ink':(60,55,100),'plug':(200,150,150)}
        for cl in ['plug','base','shade','deep','light','ink']:
            for a in layers[cl]:
                pts=np.array([[x*s+ox,y*s+oy] for x,y in a[0]],np.int32)
                cv2.fillPoly(vis,[pts],col[cl])
        if root is not None: cv2.circle(vis,tuple(int(v) for v in root),5,(255,0,0),-1)
        tv=(tw*255).astype(np.uint8); vis[tv>40]=(vis[tv>40]*0.5+np.array([255,140,0])*0.5).astype(np.uint8)
        cv2.imwrite(f'tr{i}_{k}.png',cv2.cvtColor(vis,cv2.COLOR_RGB2BGR))
    return poses
if __name__=='__main__':
    out={}
    for i,name in {1:'tsukiko',2:'lumi',3:'yuko'}.items():
        out[name]=trace(i,name)
        print(name,[sum(len(c['p']) for v in p['layers'].values() for c in v) for p in out[name]])
    json.dump(out,open('traced.json','w'))

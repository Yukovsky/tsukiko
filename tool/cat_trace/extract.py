import sys, json
import numpy as np, cv2
import os
R=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','design','cat_sheets')
def cells(img):
    h,w=img.shape[:2]
    out=[]
    for row in range(2):
        for col in range(3):
            x0=col*w//3; x1=(col+1)*w//3
            y0=95 if row==0 else h//2+20; y1=h//2+20 if row==0 else h
            out.append((x0,y0,x1,y1))
    return out
def silhouette(img, box):
    x0,y0,x1,y1=box
    crop=img[y0:y1,x0:x1].astype(np.int32)
    bg=np.median(np.concatenate([crop[:5].reshape(-1,3),crop[-5:].reshape(-1,3)]),axis=0)
    d=np.abs(crop-bg).sum(axis=2)
    mask=(d>38).astype(np.uint8)*255
    mask=cv2.morphologyEx(mask,cv2.MORPH_CLOSE,np.ones((5,5),np.uint8))
    n,lab,stats,_=cv2.connectedComponentsWithStats(mask)
    big=1+np.argmax(stats[1:,cv2.CC_STAT_AREA])
    m=(lab==big).astype(np.uint8)*255
    # fill holes
    ff=m.copy(); hh,ww=m.shape
    fm=np.zeros((hh+2,ww+2),np.uint8); cv2.floodFill(ff,fm,(0,0),255)
    m=m|cv2.bitwise_not(ff)
    cs,_=cv2.findContours(m,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_NONE)
    c=max(cs,key=cv2.contourArea)[:,0,:]
    return m,c+np.array([x0,y0])
if __name__=='__main__':
    i=int(sys.argv[1])
    img=cv2.cvtColor(cv2.imread(f'{R}/{['','tsukiko','lumi','yuko'][i]}.webp'),cv2.COLOR_BGR2RGB)
    vis=img.copy()
    res=[]
    for k,box in enumerate(cells(img)):
        m,c=silhouette(img,box)
        res.append(c.tolist())
        cv2.polylines(vis,[c.reshape(-1,1,2)],True,(255,0,0),2)
        cv2.rectangle(vis,box[:2],box[2:],(0,200,0),1)
    cv2.imwrite(f'sil{i}.png',cv2.cvtColor(vis,cv2.COLOR_RGB2BGR))
    json.dump(res,open(f'sil{i}.json','w'))
    print([len(r) for r in res])

// GuoDuo 本地补丁（2026-11-23）：Medusa 设备段按绿果TV 2.0.8 补全（Amor5207/lvguo-tv web/internal/sign/v5.go，GPL-3.0），
// 字段 16 sec_device_token、设备浮点/时间段、env 段 1/2/3/5/7/13、nested 305/4/694367、字段 21=312。
// 不补全时 video_tab / multi_video_model 一律返回 HTTP 200 空包。
function flt(tag, value) { const b = Buffer.alloc(4); b.writeFloatLE(value); return Buffer.concat([varint(tag * 8 + 5), b]); }
function protoX(fields) { return Buffer.concat(fields.map(f => f[2] === 'flt' ? flt(f[0], f[1]) : proto([f]))); }
const SEC_TOKEN = 'A' + PROCESS_NONCE.slice(0, 24);
function medusa(query, f13, ts, who) {
  const flags = Buffer.from('4480000000000000', 'hex');
  const now = Date.now(), brand = who.device_brand || 'HONOR', dt = who.device_type;
  const device = protoX([[1,1,'sint'],[2,2,'sint'],[3,'8662'],[4,who.device_id],[5,SEC_TOKEN],[6,'!noperm!'],
    [7,-888888,'sint'],[8,-888888,'sint'],[9,3,'sint'],[10,-888888,'sint'],[11,'!notset!'],[12,'Asia/Shanghai,8'],[13,'zh_CN'],
    [14,4,'sint'],[16,0,'flt'],[17,0,'flt'],[18,0,'flt'],[19,0,'flt'],[20,0,'flt'],[21,0,'flt'],
    [22,who.os_version],[23,41,'sint'],[24,36,'sint'],[25,PROCESS_STARTED,'sint'],[26,PROCESS_STARTED,'sint'],[27,PROCESS_STARTED,'sint'],[28,now,'sint'],
    [29,-1,'sint'],[30,dt],[31,brand],[32,dt],[33,dt],[34,brand],[35,brand],[36,brand],[38,31,'sint']]);
  const envSub13 = proto([[1,ts,'sint'],[2,-2,'sint'],[4,200,'sint']]);
  const env = proto([[1,100 + Math.floor(Math.random()*21),'sint'],[2,247235599,'sint'],[3,247235596,'sint'],[5,7,'sint'],
    [6,'v04.10.03.04-bugfix'],[7,10001 + Math.floor(Math.random()*2000),'sint'],[8,who.channel],[12,device],[13,envSub13],[14,who.version_name]]);
  const message = proto([[1,MAGIC],[2,5,'sint'],[3,random32(),'sint'],[4,'8662'],[5,who.device_id],
    [6,'646637794'],[7,who.version_name],[8,'v04.10.03-ml-android'],[9,0x040a0300,'sint'],
    [10,flags],[12,ts,'sint'],[13,f13],[14,query.subarray(0,6)],
    [15,proto([[1,305,'sint'],[2,4,'sint'],[3,694367,'sint'],[5,1621072674,'sint']])],
    [16,SEC_TOKEN],[17,ts,'sint'],[20,'none'],[21,312,'sint'],[23,env],
    [24,'{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}']]);
  const nonce = random32(), high = (nonce >>> 16) & 255;
  const hash = sm3(Buffer.concat([SIGN_KEY, le32(nonce), SIGN_KEY]));
  const seed = le32(~(((high << 11) | (nonce >>> 24)) ^ (high >>> 5) ^ high));
  const transformed = Buffer.concat([flags, xmxor(message, hash)]).reverse();
  for (let i = 0; i < transformed.length; i++) transformed[i] ^= seed[(~i) & 3];
  const check = 0x18000001 | ((query[0] & 63) << 14) | ((f13[0] & 63) << 8);
  const packed = Buffer.concat([Buffer.from([0xca]), le32(random32()), le32(check), transformed,
    Buffer.from([nonce >>> 16, nonce >>> 24])]);
  const encrypted = new CarrierV5(md5(SIGN_KEY.subarray(0,16)), ts).encrypt(packed, md5(SIGN_KEY.subarray(16)));
  const prefix = Buffer.concat([le32(5), MAGIC]), time = le32(ts);
  for (let i = 0; i < prefix.length; i++) prefix[i] ^= time[i & 3];
  return Buffer.concat([prefix, Buffer.from([nonce, nonce >>> 8, 0, 1]), encrypted]).toString('base64');
}


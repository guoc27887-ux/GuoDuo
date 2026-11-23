function medusa(query, f13, ts, who) {
  const flags = Buffer.alloc(8);
  const device = proto([[1,1,'sint'], [2,2,'sint'], [3,'8662'], [4,who.device_id],
    [5,PROCESS_NONCE], [6,'!noperm!'], [12,'Asia/Shanghai,8'], [13,'zh_CN'],
    [22,who.os_version], [25,PROCESS_STARTED,'sint'], [30,who.device_type], [31,'HONOR'],
    [32,who.device_type], [34,'HONOR']]);
  const env = proto([[6,'v04.10.03.04-bugfix'], [8,who.channel], [12,device], [14,who.version_name]]);
  const message = proto([[1,MAGIC], [2,5,'sint'], [3,random32(),'sint'], [4,'8662'], [5,who.device_id],
    [6,'646637794'], [7,who.version_name], [8,'v04.10.03-ml-android'], [9,0x040a0300,'sint'],
    [10,flags], [12,ts,'sint'], [13,f13], [14,query.subarray(0,6)],
    [15,proto([[1,1,'sint'], [2,1,'sint'], [3,1,'sint'], [5,1,'sint']])],
    [17,ts,'sint'], [20,'none'], [21,377,'sint'], [23,env],
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


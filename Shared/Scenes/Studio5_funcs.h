//  Studio5_funcs.h — Soap Film (shader id 71). File-scope Metal helpers, prefix "studio5_".
//
//  Model (see Studio5.swift for the look):
//   • Thickness d(x, y, t) in nm = the drainage profile D(y′) at a BACKWARD-ADVECTED point:
//     3 midpoint steps back over a fixed window through a slowly drifting, divergence-free
//     flow (the curl of a 2-octave gradient-noise stream function with analytic gradients).
//     The window is fixed, so d is a smooth function of t: no flow-map resets, no pulses.
//     Plumes are thickness deficits applied in the pre-advection frame, so the flow carries
//     and folds them too.
//   • Colour: the film's two-beam Airy reflectance is (to a few %) linear in cos δ,
//     R(λ) = A + B cos(4π o/λ) with o = n d cos θt, so its colour is A + B·C(o), where
//     C(o) = Σ_λ w(λ) cos(4π o/λ) is the CIE 1931 → linear-sRGB integral over 360–780 nm in
//     0.5 nm steps — tabulated offline (studio5_C) instead of summing a dozen wavelengths per
//     pixel: exact, and a fraction of the cost. High orders wash out to white on their own
//     (the integral averages the fringes away), and each pixel's thickness footprint (from
//     the screen derivative of d) damps cos δ per channel, so steep zones never alias.
//  Cost: everything per pixel is counted — table-gradient noise, predictors that reuse the
//  last midpoint and see only the big eddies, the colour table — ≈ 4.5 ms at 5K (M5 Pro).
//  Validation: with Turbulence and Plumes at 0 the film is a static wedge, 0 → ~1.4 µm;
//  its bands run black, grey-blue, silver, straw, gold, magenta, indigo, blue, green-yellow,
//  magenta, peacock, green, then pink/green pastels — Newton's series for a soap film.

// C(o) for o = 0, 8, 16 … 3064 nm (o = optical path n·d·cos θt). C(0) = (1, 1, 1); the
// last few entries fade to 0, so clamping past the end is the white of a thick film.
// Generated from the Wyman–Sloan–Shirley CMF fit, white-balanced to equal energy.
constant half4 studio5_C[384] = {
    half4(+1.0000h, +1.0000h, +1.0000h, 0.0h), half4(+0.9876h, +0.9831h, +0.9741h, 0.0h), half4(+0.9507h, +0.9331h, +0.8975h, 0.0h), half4(+0.8903h, +0.8515h, +0.7744h, 0.0h),
    half4(+0.8077h, +0.7411h, +0.6110h, 0.0h), half4(+0.7051h, +0.6055h, +0.4157h, 0.0h), half4(+0.5849h, +0.4494h, +0.1986h, 0.0h), half4(+0.4501h, +0.2778h, -0.0292h, 0.0h),
    half4(+0.3040h, +0.0966h, -0.2559h, 0.0h), half4(+0.1501h, -0.0883h, -0.4697h, 0.0h), half4(-0.0078h, -0.2705h, -0.6598h, 0.0h), half4(-0.1659h, -0.4439h, -0.8163h, 0.0h),
    half4(-0.3202h, -0.6027h, -0.9311h, 0.0h), half4(-0.4671h, -0.7414h, -0.9982h, 0.0h), half4(-0.6028h, -0.8552h, -1.0140h, 0.0h), half4(-0.7241h, -0.9402h, -0.9778h, 0.0h),
    half4(-0.8280h, -0.9935h, -0.8913h, 0.0h), half4(-0.9118h, -1.0130h, -0.7588h, 0.0h), half4(-0.9735h, -0.9979h, -0.5869h, 0.0h), half4(-1.0115h, -0.9486h, -0.3845h, 0.0h),
    half4(-1.0246h, -0.8667h, -0.1617h, 0.0h), half4(-1.0125h, -0.7548h, +0.0701h, 0.0h), half4(-0.9752h, -0.6165h, +0.2992h, 0.0h), half4(-0.9135h, -0.4565h, +0.5139h, 0.0h),
    half4(-0.8286h, -0.2803h, +0.7033h, 0.0h), half4(-0.7225h, -0.0937h, +0.8578h, 0.0h), half4(-0.5975h, +0.0967h, +0.9696h, 0.0h), half4(-0.4565h, +0.2845h, +1.0328h, 0.0h),
    half4(-0.3027h, +0.4632h, +1.0444h, 0.0h), half4(-0.1397h, +0.6263h, +1.0035h, 0.0h), half4(+0.0285h, +0.7683h, +0.9124h, 0.0h), half4(+0.1978h, +0.8841h, +0.7753h, 0.0h),
    half4(+0.3642h, +0.9695h, +0.5993h, 0.0h), half4(+0.5234h, +1.0213h, +0.3931h, 0.0h), half4(+0.6714h, +1.0377h, +0.1670h, 0.0h), half4(+0.8041h, +1.0178h, -0.0678h, 0.0h),
    half4(+0.9182h, +0.9623h, -0.2996h, 0.0h), half4(+1.0102h, +0.8729h, -0.5168h, 0.0h), half4(+1.0775h, +0.7526h, -0.7087h, 0.0h), half4(+1.1179h, +0.6057h, -0.8658h, 0.0h),
    half4(+1.1298h, +0.4372h, -0.9804h, 0.0h), half4(+1.1124h, +0.2530h, -1.0470h, 0.0h), half4(+1.0655h, +0.0596h, -1.0622h, 0.0h), half4(+0.9896h, -0.1362h, -1.0256h, 0.0h),
    half4(+0.8863h, -0.3274h, -0.9390h, 0.0h), half4(+0.7577h, -0.5072h, -0.8069h, 0.0h), half4(+0.6066h, -0.6691h, -0.6359h, 0.0h), half4(+0.4367h, -0.8074h, -0.4345h, 0.0h),
    half4(+0.2521h, -0.9171h, -0.2126h, 0.0h), half4(+0.0576h, -0.9943h, +0.0187h, 0.0h), half4(-0.1418h, -1.0361h, +0.2482h, 0.0h), half4(-0.3407h, -1.0411h, +0.4647h, 0.0h),
    half4(-0.5334h, -1.0092h, +0.6578h, 0.0h), half4(-0.7146h, -0.9414h, +0.8182h, 0.0h), half4(-0.8789h, -0.8403h, +0.9383h, 0.0h), half4(-1.0213h, -0.7096h, +1.0127h, 0.0h),
    half4(-1.1372h, -0.5539h, +1.0380h, 0.0h), half4(-1.2230h, -0.3791h, +1.0135h, 0.0h), half4(-1.2754h, -0.1914h, +0.9408h, 0.0h), half4(-1.2924h, +0.0025h, +0.8237h, 0.0h),
    half4(-1.2727h, +0.1953h, +0.6684h, 0.0h), half4(-1.2163h, +0.3803h, +0.4827h, 0.0h), half4(-1.1241h, +0.5508h, +0.2759h, 0.0h), half4(-0.9982h, +0.7007h, +0.0581h, 0.0h),
    half4(-0.8418h, +0.8248h, -0.1599h, 0.0h), half4(-0.6589h, +0.9186h, -0.3679h, 0.0h), half4(-0.4545h, +0.9790h, -0.5559h, 0.0h), half4(-0.2345h, +1.0042h, -0.7151h, 0.0h),
    half4(-0.0052h, +0.9933h, -0.8383h, 0.0h), half4(+0.2267h, +0.9472h, -0.9201h, 0.0h), half4(+0.4542h, +0.8678h, -0.9571h, 0.0h), half4(+0.6704h, +0.7582h, -0.9482h, 0.0h),
    half4(+0.8687h, +0.6227h, -0.8946h, 0.0h), half4(+1.0427h, +0.4664h, -0.7996h, 0.0h), half4(+1.1871h, +0.2952h, -0.6683h, 0.0h), half4(+1.2970h, +0.1155h, -0.5076h, 0.0h),
    half4(+1.3688h, -0.0663h, -0.3258h, 0.0h), half4(+1.3999h, -0.2435h, -0.1319h, 0.0h), half4(+1.3893h, -0.4098h, +0.0645h, 0.0h), half4(+1.3368h, -0.5594h, +0.2542h, 0.0h),
    half4(+1.2438h, -0.6872h, +0.4280h, 0.0h), half4(+1.1131h, -0.7889h, +0.5780h, 0.0h), half4(+0.9484h, -0.8612h, +0.6975h, 0.0h), half4(+0.7548h, -0.9020h, +0.7815h, 0.0h),
    half4(+0.5381h, -0.9103h, +0.8266h, 0.0h), half4(+0.3051h, -0.8865h, +0.8315h, 0.0h), half4(+0.0630h, -0.8319h, +0.7969h, 0.0h), half4(-0.1809h, -0.7490h, +0.7254h, 0.0h),
    half4(-0.4188h, -0.6412h, +0.6213h, 0.0h), half4(-0.6434h, -0.5130h, +0.4902h, 0.0h), half4(-0.8477h, -0.3693h, +0.3392h, 0.0h), half4(-1.0255h, -0.2154h, +0.1761h, 0.0h),
    half4(-1.1713h, -0.0571h, +0.0088h, 0.0h), half4(-1.2807h, +0.1000h, -0.1543h, 0.0h), half4(-1.3505h, +0.2503h, -0.3056h, 0.0h), half4(-1.3789h, +0.3887h, -0.4380h, 0.0h),
    half4(-1.3651h, +0.5106h, -0.5458h, 0.0h), half4(-1.3100h, +0.6121h, -0.6243h, 0.0h), half4(-1.2155h, +0.6901h, -0.6707h, 0.0h), half4(-1.0851h, +0.7425h, -0.6836h, 0.0h),
    half4(-0.9230h, +0.7681h, -0.6632h, 0.0h), half4(-0.7348h, +0.7667h, -0.6117h, 0.0h), half4(-0.5264h, +0.7391h, -0.5324h, 0.0h), half4(-0.3046h, +0.6869h, -0.4300h, 0.0h),
    half4(-0.0764h, +0.6127h, -0.3102h, 0.0h), half4(+0.1510h, +0.5197h, -0.1794h, 0.0h), half4(+0.3707h, +0.4115h, -0.0443h, 0.0h), half4(+0.5759h, +0.2924h, +0.0884h, 0.0h),
    half4(+0.7608h, +0.1667h, +0.2123h, 0.0h), half4(+0.9198h, +0.0391h, +0.3215h, 0.0h), half4(+1.0486h, -0.0862h, +0.4112h, 0.0h), half4(+1.1438h, -0.2049h, +0.4777h, 0.0h),
    half4(+1.2031h, -0.3133h, +0.5184h, 0.0h), half4(+1.2254h, -0.4079h, +0.5323h, 0.0h), half4(+1.2108h, -0.4861h, +0.5195h, 0.0h), half4(+1.1605h, -0.5458h, +0.4816h, 0.0h),
    half4(+1.0768h, -0.5857h, +0.4214h, 0.0h), half4(+0.9629h, -0.6050h, +0.3426h, 0.0h), half4(+0.8229h, -0.6040h, +0.2499h, 0.0h), half4(+0.6617h, -0.5832h, +0.1483h, 0.0h),
    half4(+0.4845h, -0.5442h, +0.0432h, 0.0h), half4(+0.2972h, -0.4889h, -0.0600h, 0.0h), half4(+0.1054h, -0.4197h, -0.1562h, 0.0h), half4(-0.0850h, -0.3393h, -0.2408h, 0.0h),
    half4(-0.2685h, -0.2508h, -0.3099h, 0.0h), half4(-0.4397h, -0.1573h, -0.3608h, 0.0h), half4(-0.5940h, -0.0621h, -0.3914h, 0.0h), half4(-0.7273h, +0.0318h, -0.4010h, 0.0h),
    half4(-0.8363h, +0.1215h, -0.3898h, 0.0h), half4(-0.9186h, +0.2042h, -0.3593h, 0.0h), half4(-0.9724h, +0.2776h, -0.3117h, 0.0h), half4(-0.9971h, +0.3398h, -0.2501h, 0.0h),
    half4(-0.9928h, +0.3892h, -0.1781h, 0.0h), half4(-0.9604h, +0.4250h, -0.0998h, 0.0h), half4(-0.9017h, +0.4463h, -0.0195h, 0.0h), half4(-0.8192h, +0.4533h, +0.0586h, 0.0h),
    half4(-0.7158h, +0.4462h, +0.1306h, 0.0h), half4(-0.5952h, +0.4258h, +0.1930h, 0.0h), half4(-0.4612h, +0.3933h, +0.2429h, 0.0h), half4(-0.3180h, +0.3500h, +0.2782h, 0.0h),
    half4(-0.1699h, +0.2977h, +0.2976h, 0.0h), half4(-0.0211h, +0.2382h, +0.3007h, 0.0h), half4(+0.1242h, +0.1737h, +0.2880h, 0.0h), half4(+0.2621h, +0.1062h, +0.2606h, 0.0h),
    half4(+0.3891h, +0.0378h, +0.2206h, 0.0h), half4(+0.5020h, -0.0294h, +0.1706h, 0.0h), half4(+0.5980h, -0.0936h, +0.1134h, 0.0h), half4(+0.6751h, -0.1529h, +0.0523h, 0.0h),
    half4(+0.7318h, -0.2059h, -0.0092h, 0.0h), half4(+0.7671h, -0.2512h, -0.0681h, 0.0h), half4(+0.7806h, -0.2877h, -0.1212h, 0.0h), half4(+0.7727h, -0.3148h, -0.1659h, 0.0h),
    half4(+0.7440h, -0.3319h, -0.2003h, 0.0h), half4(+0.6961h, -0.3388h, -0.2229h, 0.0h), half4(+0.6306h, -0.3357h, -0.2329h, 0.0h), half4(+0.5498h, -0.3230h, -0.2302h, 0.0h),
    half4(+0.4563h, -0.3013h, -0.2154h, 0.0h), half4(+0.3529h, -0.2714h, -0.1896h, 0.0h), half4(+0.2426h, -0.2346h, -0.1547h, 0.0h), half4(+0.1285h, -0.1919h, -0.1128h, 0.0h),
    half4(+0.0139h, -0.1448h, -0.0663h, 0.0h), half4(-0.0984h, -0.0948h, -0.0178h, 0.0h), half4(-0.2053h, -0.0433h, +0.0300h, 0.0h), half4(-0.3041h, +0.0081h, +0.0747h, 0.0h),
    half4(-0.3924h, +0.0580h, +0.1140h, 0.0h), half4(-0.4680h, +0.1049h, +0.1460h, 0.0h), half4(-0.5294h, +0.1476h, +0.1693h, 0.0h), half4(-0.5750h, +0.1849h, +0.1830h, 0.0h),
    half4(-0.6041h, +0.2159h, +0.1866h, 0.0h), half4(-0.6163h, +0.2397h, +0.1804h, 0.0h), half4(-0.6117h, +0.2560h, +0.1648h, 0.0h), half4(-0.5906h, +0.2643h, +0.1412h, 0.0h),
    half4(-0.5541h, +0.2645h, +0.1110h, 0.0h), half4(-0.5035h, +0.2569h, +0.0759h, 0.0h), half4(-0.4405h, +0.2419h, +0.0381h, 0.0h), half4(-0.3669h, +0.2200h, -0.0006h, 0.0h),
    half4(-0.2852h, +0.1921h, -0.0379h, 0.0h), half4(-0.1976h, +0.1591h, -0.0720h, 0.0h), half4(-0.1067h, +0.1222h, -0.1013h, 0.0h), half4(-0.0151h, +0.0825h, -0.1243h, 0.0h),
    half4(+0.0748h, +0.0414h, -0.1402h, 0.0h), half4(+0.1605h, +0.0001h, -0.1483h, 0.0h), half4(+0.2398h, -0.0402h, -0.1485h, 0.0h), half4(+0.3106h, -0.0781h, -0.1411h, 0.0h),
    half4(+0.3711h, -0.1126h, -0.1268h, 0.0h), half4(+0.4200h, -0.1427h, -0.1065h, 0.0h), half4(+0.4561h, -0.1676h, -0.0814h, 0.0h), half4(+0.4788h, -0.1866h, -0.0532h, 0.0h),
    half4(+0.4877h, -0.1993h, -0.0233h, 0.0h), half4(+0.4830h, -0.2055h, +0.0066h, 0.0h), half4(+0.4651h, -0.2051h, +0.0350h, 0.0h), half4(+0.4349h, -0.1984h, +0.0605h, 0.0h),
    half4(+0.3935h, -0.1858h, +0.0819h, 0.0h), half4(+0.3424h, -0.1678h, +0.0982h, 0.0h), half4(+0.2832h, -0.1452h, +0.1090h, 0.0h), half4(+0.2180h, -0.1189h, +0.1137h, 0.0h),
    half4(+0.1485h, -0.0898h, +0.1125h, 0.0h), half4(+0.0770h, -0.0590h, +0.1056h, 0.0h), half4(+0.0055h, -0.0275h, +0.0938h, 0.0h), half4(-0.0640h, +0.0037h, +0.0777h, 0.0h),
    half4(-0.1296h, +0.0335h, +0.0585h, 0.0h), half4(-0.1896h, +0.0611h, +0.0373h, 0.0h), half4(-0.2424h, +0.0856h, +0.0152h, 0.0h), half4(-0.2869h, +0.1064h, -0.0066h, 0.0h),
    half4(-0.3220h, +0.1230h, -0.0269h, 0.0h), half4(-0.3471h, +0.1349h, -0.0447h, 0.0h), half4(-0.3618h, +0.1421h, -0.0594h, 0.0h), half4(-0.3660h, +0.1445h, -0.0702h, 0.0h),
    half4(-0.3601h, +0.1423h, -0.0768h, 0.0h), half4(-0.3445h, +0.1357h, -0.0792h, 0.0h), half4(-0.3200h, +0.1252h, -0.0774h, 0.0h), half4(-0.2877h, +0.1113h, -0.0717h, 0.0h),
    half4(-0.2487h, +0.0947h, -0.0628h, 0.0h), half4(-0.2044h, +0.0761h, -0.0512h, 0.0h), half4(-0.1562h, +0.0561h, -0.0376h, 0.0h), half4(-0.1056h, +0.0356h, -0.0231h, 0.0h),
    half4(-0.0542h, +0.0152h, -0.0083h, 0.0h), half4(-0.0033h, -0.0045h, +0.0059h, 0.0h), half4(+0.0456h, -0.0228h, +0.0188h, 0.0h), half4(+0.0914h, -0.0392h, +0.0297h, 0.0h),
    half4(+0.1328h, -0.0533h, +0.0383h, 0.0h), half4(+0.1690h, -0.0648h, +0.0442h, 0.0h), half4(+0.1991h, -0.0736h, +0.0473h, 0.0h), half4(+0.2228h, -0.0795h, +0.0476h, 0.0h),
    half4(+0.2396h, -0.0826h, +0.0454h, 0.0h), half4(+0.2493h, -0.0830h, +0.0408h, 0.0h), half4(+0.2522h, -0.0808h, +0.0344h, 0.0h), half4(+0.2483h, -0.0765h, +0.0266h, 0.0h),
    half4(+0.2382h, -0.0703h, +0.0181h, 0.0h), half4(+0.2224h, -0.0625h, +0.0093h, 0.0h), half4(+0.2016h, -0.0536h, +0.0008h, 0.0h), half4(+0.1767h, -0.0440h, -0.0069h, 0.0h),
    half4(+0.1483h, -0.0340h, -0.0134h, 0.0h), half4(+0.1175h, -0.0240h, -0.0184h, 0.0h), half4(+0.0852h, -0.0143h, -0.0218h, 0.0h), half4(+0.0522h, -0.0052h, -0.0235h, 0.0h),
    half4(+0.0194h, +0.0031h, -0.0235h, 0.0h), half4(-0.0124h, +0.0104h, -0.0219h, 0.0h), half4(-0.0424h, +0.0168h, -0.0190h, 0.0h), half4(-0.0701h, +0.0220h, -0.0152h, 0.0h),
    half4(-0.0948h, +0.0261h, -0.0107h, 0.0h), half4(-0.1161h, +0.0291h, -0.0059h, 0.0h), half4(-0.1338h, +0.0312h, -0.0013h, 0.0h), half4(-0.1475h, +0.0324h, +0.0030h, 0.0h),
    half4(-0.1572h, +0.0328h, +0.0065h, 0.0h), half4(-0.1629h, +0.0326h, +0.0091h, 0.0h), half4(-0.1645h, +0.0319h, +0.0106h, 0.0h), half4(-0.1623h, +0.0308h, +0.0110h, 0.0h),
    half4(-0.1565h, +0.0294h, +0.0103h, 0.0h), half4(-0.1474h, +0.0278h, +0.0087h, 0.0h), half4(-0.1353h, +0.0261h, +0.0062h, 0.0h), half4(-0.1207h, +0.0243h, +0.0031h, 0.0h),
    half4(-0.1039h, +0.0224h, -0.0002h, 0.0h), half4(-0.0854h, +0.0205h, -0.0036h, 0.0h), half4(-0.0657h, +0.0185h, -0.0067h, 0.0h), half4(-0.0452h, +0.0164h, -0.0093h, 0.0h),
    half4(-0.0244h, +0.0142h, -0.0111h, 0.0h), half4(-0.0037h, +0.0118h, -0.0120h, 0.0h), half4(+0.0166h, +0.0091h, -0.0120h, 0.0h), half4(+0.0358h, +0.0063h, -0.0109h, 0.0h),
    half4(+0.0539h, +0.0032h, -0.0088h, 0.0h), half4(+0.0703h, -0.0002h, -0.0060h, 0.0h), half4(+0.0847h, -0.0037h, -0.0024h, 0.0h), half4(+0.0971h, -0.0074h, +0.0015h, 0.0h),
    half4(+0.1070h, -0.0112h, +0.0056h, 0.0h), half4(+0.1144h, -0.0151h, +0.0096h, 0.0h), half4(+0.1192h, -0.0188h, +0.0131h, 0.0h), half4(+0.1213h, -0.0224h, +0.0160h, 0.0h),
    half4(+0.1206h, -0.0257h, +0.0179h, 0.0h), half4(+0.1172h, -0.0285h, +0.0188h, 0.0h), half4(+0.1113h, -0.0308h, +0.0185h, 0.0h), half4(+0.1029h, -0.0324h, +0.0170h, 0.0h),
    half4(+0.0922h, -0.0333h, +0.0144h, 0.0h), half4(+0.0795h, -0.0333h, +0.0108h, 0.0h), half4(+0.0652h, -0.0325h, +0.0064h, 0.0h), half4(+0.0494h, -0.0308h, +0.0014h, 0.0h),
    half4(+0.0326h, -0.0281h, -0.0039h, 0.0h), half4(+0.0151h, -0.0247h, -0.0091h, 0.0h), half4(-0.0025h, -0.0204h, -0.0140h, 0.0h), half4(-0.0200h, -0.0155h, -0.0182h, 0.0h),
    half4(-0.0369h, -0.0101h, -0.0215h, 0.0h), half4(-0.0527h, -0.0042h, -0.0237h, 0.0h), half4(-0.0671h, +0.0019h, -0.0245h, 0.0h), half4(-0.0798h, +0.0081h, -0.0239h, 0.0h),
    half4(-0.0903h, +0.0142h, -0.0219h, 0.0h), half4(-0.0985h, +0.0199h, -0.0186h, 0.0h), half4(-0.1041h, +0.0252h, -0.0142h, 0.0h), half4(-0.1070h, +0.0297h, -0.0088h, 0.0h),
    half4(-0.1072h, +0.0335h, -0.0028h, 0.0h), half4(-0.1045h, +0.0364h, +0.0035h, 0.0h), half4(-0.0991h, +0.0382h, +0.0098h, 0.0h), half4(-0.0912h, +0.0390h, +0.0157h, 0.0h),
    half4(-0.0809h, +0.0386h, +0.0208h, 0.0h), half4(-0.0686h, +0.0371h, +0.0248h, 0.0h), half4(-0.0546h, +0.0346h, +0.0276h, 0.0h), half4(-0.0393h, +0.0310h, +0.0288h, 0.0h),
    half4(-0.0231h, +0.0266h, +0.0285h, 0.0h), half4(-0.0066h, +0.0214h, +0.0266h, 0.0h), half4(+0.0100h, +0.0156h, +0.0231h, 0.0h), half4(+0.0260h, +0.0094h, +0.0184h, 0.0h),
    half4(+0.0411h, +0.0029h, +0.0125h, 0.0h), half4(+0.0548h, -0.0037h, +0.0058h, 0.0h), half4(+0.0667h, -0.0101h, -0.0013h, 0.0h), half4(+0.0766h, -0.0162h, -0.0085h, 0.0h),
    half4(+0.0842h, -0.0217h, -0.0153h, 0.0h), half4(+0.0893h, -0.0267h, -0.0214h, 0.0h), half4(+0.0918h, -0.0308h, -0.0265h, 0.0h), half4(+0.0917h, -0.0340h, -0.0302h, 0.0h),
    half4(+0.0890h, -0.0362h, -0.0323h, 0.0h), half4(+0.0839h, -0.0374h, -0.0327h, 0.0h), half4(+0.0765h, -0.0375h, -0.0314h, 0.0h), half4(+0.0672h, -0.0365h, -0.0284h, 0.0h),
    half4(+0.0563h, -0.0345h, -0.0238h, 0.0h), half4(+0.0440h, -0.0315h, -0.0178h, 0.0h), half4(+0.0309h, -0.0277h, -0.0109h, 0.0h), half4(+0.0173h, -0.0231h, -0.0032h, 0.0h),
    half4(+0.0036h, -0.0179h, +0.0047h, 0.0h), half4(-0.0098h, -0.0122h, +0.0124h, 0.0h), half4(-0.0225h, -0.0063h, +0.0196h, 0.0h), half4(-0.0341h, -0.0002h, +0.0259h, 0.0h),
    half4(-0.0444h, +0.0058h, +0.0308h, 0.0h), half4(-0.0531h, +0.0115h, +0.0342h, 0.0h), half4(-0.0600h, +0.0169h, +0.0359h, 0.0h), half4(-0.0650h, +0.0217h, +0.0357h, 0.0h),
    half4(-0.0680h, +0.0258h, +0.0337h, 0.0h), half4(-0.0690h, +0.0292h, +0.0298h, 0.0h), half4(-0.0680h, +0.0317h, +0.0245h, 0.0h), half4(-0.0653h, +0.0332h, +0.0178h, 0.0h),
    half4(-0.0608h, +0.0337h, +0.0101h, 0.0h), half4(-0.0549h, +0.0333h, +0.0019h, 0.0h), half4(-0.0478h, +0.0319h, -0.0064h, 0.0h), half4(-0.0397h, +0.0297h, -0.0145h, 0.0h),
    half4(-0.0308h, +0.0265h, -0.0219h, 0.0h), half4(-0.0216h, +0.0227h, -0.0282h, 0.0h), half4(-0.0122h, +0.0182h, -0.0331h, 0.0h), half4(-0.0029h, +0.0133h, -0.0364h, 0.0h),
    half4(+0.0060h, +0.0081h, -0.0378h, 0.0h), half4(+0.0144h, +0.0026h, -0.0373h, 0.0h), half4(+0.0220h, -0.0028h, -0.0349h, 0.0h), half4(+0.0287h, -0.0081h, -0.0307h, 0.0h),
    half4(+0.0343h, -0.0130h, -0.0250h, 0.0h), half4(+0.0389h, -0.0175h, -0.0181h, 0.0h), half4(+0.0422h, -0.0215h, -0.0102h, 0.0h), half4(+0.0444h, -0.0247h, -0.0019h, 0.0h),
    half4(+0.0454h, -0.0271h, +0.0066h, 0.0h), half4(+0.0453h, -0.0287h, +0.0147h, 0.0h), half4(+0.0441h, -0.0294h, +0.0220h, 0.0h), half4(+0.0419h, -0.0292h, +0.0283h, 0.0h),
    half4(+0.0388h, -0.0282h, +0.0331h, 0.0h), half4(+0.0350h, -0.0263h, +0.0362h, 0.0h), half4(+0.0305h, -0.0236h, +0.0375h, 0.0h), half4(+0.0256h, -0.0203h, +0.0370h, 0.0h),
    half4(+0.0202h, -0.0164h, +0.0346h, 0.0h), half4(+0.0146h, -0.0120h, +0.0305h, 0.0h), half4(+0.0088h, -0.0074h, +0.0249h, 0.0h), half4(+0.0030h, -0.0026h, +0.0181h, 0.0h),
    half4(-0.0026h, +0.0021h, +0.0105h, 0.0h), half4(-0.0081h, +0.0067h, +0.0024h, 0.0h), half4(-0.0133h, +0.0110h, -0.0057h, 0.0h), half4(-0.0180h, +0.0149h, -0.0135h, 0.0h),
    half4(-0.0222h, +0.0182h, -0.0205h, 0.0h), half4(-0.0259h, +0.0209h, -0.0265h, 0.0h), half4(-0.0289h, +0.0229h, -0.0311h, 0.0h), half4(-0.0313h, +0.0241h, -0.0340h, 0.0h),
    half4(-0.0329h, +0.0245h, -0.0353h, 0.0h), half4(-0.0337h, +0.0241h, -0.0348h, 0.0h), half4(-0.0337h, +0.0230h, -0.0326h, 0.0h), half4(-0.0330h, +0.0212h, -0.0288h, 0.0h),
    half4(-0.0314h, +0.0187h, -0.0236h, 0.0h), half4(-0.0292h, +0.0157h, -0.0174h, 0.0h), half4(-0.0262h, +0.0122h, -0.0103h, 0.0h), half4(-0.0226h, +0.0085h, -0.0028h, 0.0h),
    half4(-0.0169h, +0.0042h, +0.0043h, 0.0h), half4(-0.0115h, +0.0005h, +0.0098h, 0.0h), half4(-0.0066h, -0.0024h, +0.0137h, 0.0h), half4(-0.0024h, -0.0046h, +0.0158h, 0.0h),
    half4(+0.0010h, -0.0059h, +0.0163h, 0.0h), half4(+0.0034h, -0.0065h, +0.0153h, 0.0h), half4(+0.0049h, -0.0064h, +0.0133h, 0.0h), half4(+0.0055h, -0.0057h, +0.0105h, 0.0h),
    half4(+0.0052h, -0.0046h, +0.0073h, 0.0h), half4(+0.0041h, -0.0031h, +0.0043h, 0.0h), half4(+0.0023h, -0.0015h, +0.0018h, 0.0h), half4(+0.0000h, -0.0000h, +0.0000h, 0.0h),
};

// Lattice gradients: 256 unit vectors (stratified angles, shuffled) on a 16×16 periodic
// lattice. A table lookup is far cheaper than hashing, and the noise below runs about ten
// times per pixel. The period is 16 cells: ≥ 7 screen heights for the big eddies, and the
// octaves sit on rotated, scaled lattices, so it never shows.
constant float2 studio5_G[256] = {
    float2(-0.4760, -0.8795), float2(-0.7007, -0.7134), float2(-0.9770, +0.2133), float2(-0.3234, -0.9463), float2(-0.7789, +0.6271), float2(-0.8092, -0.5875), float2(-0.1377, -0.9905), float2(-0.5434, +0.8394),
    float2(-0.1117, +0.9937), float2(-0.1628, +0.9867), float2(+0.9605, +0.2783), float2(-0.5606, -0.8281), float2(-0.6449, -0.7643), float2(+0.9824, -0.1867), float2(-0.2830, -0.9591), float2(-0.9840, -0.1779),
    float2(+0.5892, +0.8080), float2(-0.9388, +0.3444), float2(+0.7637, +0.6456), float2(+0.6210, -0.7838), float2(+0.5062, +0.8624), float2(+0.8641, -0.5032), float2(+0.0558, +0.9984), float2(+0.8957, -0.4446),
    float2(+0.3874, -0.9219), float2(+0.9515, -0.3075), float2(-0.9468, -0.3218), float2(-0.9304, +0.3665), float2(-0.6060, -0.7954), float2(-0.9982, +0.0596), float2(+0.8856, -0.4645), float2(-0.1385, +0.9904),
    float2(-0.9947, +0.1030), float2(+0.7165, -0.6976), float2(+0.9662, -0.2580), float2(+0.7364, +0.6765), float2(+1.0000, +0.0095), float2(-0.0076, -1.0000), float2(+0.5428, -0.8398), float2(-0.7016, +0.7126),
    float2(-0.2297, +0.9733), float2(+0.4151, +0.9098), float2(+0.2361, +0.9717), float2(-0.7318, -0.6816), float2(-0.0325, -0.9995), float2(-0.5401, -0.8416), float2(-0.5692, +0.8222), float2(-0.9017, +0.4324),
    float2(+0.2083, -0.9781), float2(+0.4099, -0.9121), float2(+0.0302, -0.9995), float2(+0.9916, -0.1294), float2(+0.6073, +0.7945), float2(-0.4827, +0.8758), float2(+0.8956, +0.4449), float2(-0.6474, +0.7621),
    float2(+0.6847, +0.7288), float2(+0.4643, -0.8857), float2(+0.0132, -0.9999), float2(-0.9833, +0.1818), float2(-0.3649, +0.9311), float2(-0.3497, -0.9369), float2(+0.8095, +0.5871), float2(+0.8277, +0.5612),
    float2(+0.7023, -0.7118), float2(-0.9002, -0.4354), float2(-0.9744, -0.2249), float2(+0.9204, -0.3910), float2(-0.2498, -0.9683), float2(-0.8731, +0.4876), float2(-0.0664, -0.9978), float2(+0.6642, +0.7476),
    float2(+0.8781, -0.4784), float2(+0.6383, -0.7698), float2(-0.9784, -0.2068), float2(-0.0652, +0.9979), float2(-0.8416, -0.5401), float2(+0.7833, -0.6217), float2(-0.7514, +0.6598), float2(-0.8862, +0.4633),
    float2(-0.5813, -0.8137), float2(-0.3442, +0.9389), float2(+0.9728, -0.2317), float2(-0.6605, -0.7508), float2(-0.4628, +0.8865), float2(+0.6570, -0.7539), float2(-0.8492, -0.5280), float2(+0.9797, -0.2003),
    float2(+0.7448, -0.6672), float2(-0.2028, +0.9792), float2(-0.9366, -0.3503), float2(+0.4403, +0.8978), float2(+0.8129, -0.5824), float2(+0.1564, +0.9877), float2(-0.5250, +0.8511), float2(-0.2767, +0.9610),
    float2(+0.9115, -0.4113), float2(-0.4443, +0.8959), float2(-0.1643, -0.9864), float2(-0.3069, -0.9517), float2(-0.9995, +0.0301), float2(+0.9283, -0.3718), float2(+0.8499, -0.5270), float2(-0.9676, +0.2526),
    float2(-0.7982, -0.6024), float2(+0.3671, +0.9302), float2(-0.9999, +0.0117), float2(+0.8231, -0.5679), float2(-0.8546, +0.5193), float2(+0.9516, +0.3073), float2(+0.9073, +0.4205), float2(+0.5021, -0.8648),
    float2(+0.1395, -0.9902), float2(-0.2608, +0.9654), float2(-0.9517, +0.3070), float2(+0.7930, -0.6092), float2(-0.3011, +0.9536), float2(+0.2380, -0.9713), float2(+0.6967, +0.7173), float2(+0.7822, +0.6230),
    float2(-0.7149, +0.6992), float2(-0.9531, -0.3028), float2(-0.4175, -0.9087), float2(+0.2547, -0.9670), float2(-0.4172, +0.9088), float2(+0.9186, +0.3951), float2(-0.0834, -0.9965), float2(-0.0390, +0.9992),
    float2(+0.9992, +0.0406), float2(-0.5909, +0.8067), float2(-0.9119, -0.4103), float2(+0.3212, +0.9470), float2(-0.3893, -0.9211), float2(+0.8401, -0.5425), float2(+0.9864, +0.1644), float2(+0.3779, -0.9258),
    float2(-0.9943, -0.1064), float2(+0.3313, -0.9435), float2(-0.0828, +0.9966), float2(+0.1860, -0.9825), float2(+0.1557, -0.9878), float2(+0.5607, -0.8280), float2(+0.9366, -0.3504), float2(+0.2720, -0.9623),
    float2(-0.9175, +0.3976), float2(-0.7814, -0.6240), float2(+0.9872, -0.1592), float2(+0.8781, +0.4785), float2(+0.9447, +0.3279), float2(+0.9789, +0.2044), float2(-0.9169, -0.3991), float2(-0.8639, -0.5037),
    float2(-0.9863, +0.1647), float2(+0.0891, +0.9960), float2(+0.3940, +0.9191), float2(+0.3430, -0.9393), float2(-0.7489, -0.6626), float2(+0.7963, +0.6049), float2(-0.9616, +0.2746), float2(+0.5471, +0.8371),
    float2(-0.3260, +0.9454), float2(-0.9880, -0.1547), float2(-0.1898, +0.9818), float2(+0.4548, +0.8906), float2(-0.9982, -0.0606), float2(-0.8230, -0.5681), float2(-0.3728, -0.9279), float2(+0.9976, +0.0686),
    float2(+0.7175, +0.6966), float2(-0.9999, -0.0148), float2(+0.7474, +0.6643), float2(-0.9713, +0.2378), float2(+0.0861, -0.9963), float2(+0.5717, +0.8205), float2(-0.9434, +0.3316), float2(-0.2106, -0.9776),
    float2(-0.5074, -0.8617), float2(-0.4348, -0.9005), float2(+0.9686, +0.2485), float2(+0.2514, +0.9679), float2(+0.8532, +0.5216), float2(+0.9463, -0.3234), float2(+0.9984, -0.0570), float2(-0.8359, +0.5489),
    float2(-0.9918, +0.1279), float2(-0.1877, -0.9822), float2(+0.8876, +0.4606), float2(+0.9292, +0.3696), float2(+0.4332, -0.9013), float2(+0.9356, +0.3530), float2(+0.8635, +0.5044), float2(-0.2288, -0.9735),
    float2(-0.7290, +0.6845), float2(-0.7638, +0.6454), float2(-0.9905, -0.1378), float2(+0.6203, +0.7844), float2(-0.4626, -0.8866), float2(+0.9586, -0.2848), float2(-0.7108, -0.7034), float2(+0.9731, +0.2306),
    float2(+0.5221, -0.8529), float2(+0.6061, -0.7954), float2(+0.6757, -0.7372), float2(-0.0158, +0.9999), float2(+0.4806, +0.8769), float2(+0.3078, +0.9515), float2(+0.5909, -0.8068), float2(+0.9994, -0.0353),
    float2(+0.9966, -0.0829), float2(-0.7930, +0.6092), float2(+0.9826, +0.1857), float2(+0.1030, -0.9947), float2(-0.1173, -0.9931), float2(-0.8646, +0.5024), float2(+0.2781, +0.9605), float2(+0.1057, +0.9944),
    float2(+0.1285, +0.9917), float2(+0.2045, +0.9789), float2(-0.6196, +0.7849), float2(-0.5213, -0.8534), float2(-0.9601, -0.2797), float2(-0.6256, -0.7801), float2(+0.0673, -0.9977), float2(-0.9965, +0.0841),
    float2(+0.9903, +0.1389), float2(+0.8380, +0.5456), float2(-0.3875, +0.9219), float2(+0.0092, +1.0000), float2(-0.9105, +0.4135), float2(-0.6673, +0.7448), float2(-0.8765, -0.4814), float2(+0.9931, -0.1173),
    float2(+0.3476, +0.9376), float2(-0.5030, +0.8643), float2(-0.6829, -0.7305), float2(-0.9992, -0.0403), float2(-0.7646, -0.6445), float2(+0.7677, -0.6408), float2(+0.6421, +0.7666), float2(-0.9958, -0.0920),
    float2(+0.9965, +0.0841), float2(+0.9934, +0.1145), float2(-0.8862, -0.4634), float2(+0.5198, +0.8543), float2(+0.4791, -0.8778), float2(+0.1800, +0.9837), float2(-0.9676, -0.2525), float2(+0.3021, -0.9533),
    float2(-0.6093, +0.7929), float2(+0.7373, -0.6755), float2(-0.9282, -0.3721), float2(-0.8125, +0.5829), float2(-0.8272, +0.5619), float2(+0.0340, +0.9994), float2(+1.0000, -0.0098), float2(-0.6767, +0.7362),
};
static inline int studio5_cell(int2 c) { return (c.x & 15) | ((c.y & 15) << 4); }

// Quintic gradient noise (C2, so the velocity's strain is continuous across cells: no
// creases along the lattice) with its analytic gradient: (n, ∂n/∂x, ∂n/∂y).
static inline float3 studio5_noised(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    int2 c = int2(i);
    float2 ga = studio5_G[studio5_cell(c)], gb = studio5_G[studio5_cell(c + int2(1, 0))];
    float2 gc = studio5_G[studio5_cell(c + int2(0, 1))], gd = studio5_G[studio5_cell(c + int2(1, 1))];
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float k = va - vb - vc + vd;
    float v = va + w.x * (vb - va) + w.y * (vc - va) + w.x * w.y * k;
    float2 g = ga + w.x * (gb - ga) + w.y * (gc - ga) + w.x * w.y * (ga - gb - gc + gd)
             + dw * (w.yx * k + float2(vb - va, vc - va));
    return float3(v, g);
}

// Value only (≈ ±0.7).
static inline float studio5_noise(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    int2 c = int2(i);
    float va = dot(studio5_G[studio5_cell(c)], f);
    float vb = dot(studio5_G[studio5_cell(c + int2(1, 0))], f - float2(1, 0));
    float vc = dot(studio5_G[studio5_cell(c + int2(0, 1))], f - float2(0, 1));
    float vd = dot(studio5_G[studio5_cell(c + int2(1, 1))], f - float2(1, 1));
    return mix(mix(va, vb, w.x), mix(vc, vd, w.x), w.y);
}

struct Studio5Flow {
    float2 o1, o2;      // drifting offsets of the two octaves (noise units)
    float fs;           // large-octave frequency (per screen height)
    float amp;          // stream-function amplitude (≈ displacement over the window)
    float buoy;         // upward drift at the bottom margin
    float calmTop;      // 1: the flow quietens toward the top (soap); 0: uniform (oil)
    float hb;           // height of the black-film line (soap): calm above it
    float2 env;         // the height envelope (e, de/dy) at the trajectory's start
};

// Velocity = curl of the stream function Ψ = amp·e(y)·(n1 + a2·n2): (∂Ψ/∂y, −∂Ψ/∂x).
// Divergence-free, so the film never piles up or thins out by compression, it only folds.
// e(y) quietens the flow toward the black film (∇(eψ) = e∇ψ + ψ∇e) over a long, gentle
// ramp (a steep one would shear the bands into horizontal seams); it barely changes over
// one window, so it is taken at the trajectory's start: (e, de/dy) in F.env.
// a2 = 0 leaves out the small eddies.
static inline float2 studio5_vel(float2 p, thread const Studio5Flow& F, float a2) {
    const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
    const float f2 = 2.13;
    float3 n = studio5_noised(p * F.fs + F.o1);
    if (a2 > 0.0) {
        float3 n2 = studio5_noised(R * (p * (F.fs * f2)) + F.o2);
        n += float3(a2 * n2.x, (a2 * f2) * (transpose(R) * n2.yz));
    }
    float2 g = F.env.x * F.fs * n.yz + float2(0.0, n.x * F.env.y);
    return F.amp * float2(g.y, -g.x);
}

// Backward advection over the fixed window (the field is frozen within a frame and drifts
// between frames, so the result is smooth in t): 3 midpoint steps — a composition of smooth
// maps, so no tears and no resets. A predictor only places its step's midpoint, so after
// the first it reuses the previous midpoint's velocity (half a step stale: still second
// order) and sees just the big eddies; the small ones join in the last step. Five noise
// lookups instead of twelve.
static inline float2 studio5_advect(float2 p, thread Studio5Flow& F) {
    float h = p.y + 0.5;
    const float span = -0.70;                            // smoothstep from hb + 0.05 down to hb − 0.65
    float s = saturate((h - F.hb - 0.05) * (1.0 / span));
    F.env = float2(1.0 - F.calmTop * 0.82 * (1.0 - s * s * (3.0 - 2.0 * s)),
                   F.calmTop * 0.82 * 6.0 * s * (1.0 - s) * (1.0 / span));
    const float hs = 1.0 / 3.0;
    float2 v = studio5_vel(p, F, 0.0);
    for (int i = 0; i < 3; ++i) {
        v = studio5_vel(p - 0.5 * hs * v, F, i == 2 ? 1.0 : 0.0);
        p -= hs * v;
    }
    return p;
}

// Film colour (linear sRGB, 0…0.077) for optical path o (nm) changing by go across the
// pixel: A + B·⟨C(o)⟩. The pixel average of each cos(4π o σ) is damped by exp(−(Δδ)²/18),
// Δδ = 4π σ go its phase spread, with σ the channel's effective wavenumber.
static inline float3 studio5_film(float o, float go, float A, float B) {
    float x = min(o * 0.125, 382.0);
    int i = int(x);
    float3 c = mix(float3(studio5_C[i].rgb), float3(studio5_C[i + 1].rgb), x - float(i));
    float3 k = (12.566371 * go) * float3(1.0 / 600.0, 1.0 / 540.0, 1.0 / 460.0);
    return A + B * c * exp(-0.055 * k * k);
}

// Display sRGB → linear for the two colour wells (polynomial fit, |err| < 0.003).
static inline float3 studio5_lin(float3 c) {
    c = saturate(c);
    return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}

static inline float4 studio5_soapFilm(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u) {
    float speed = u.p0.x, swirl = saturate(u.p0.y), drain = saturate(u.p0.z), plumes = saturate(u.p0.w);
    bool oil = u.p1.x > 0.5;
    float sc = clamp(u.p1.y, 0.5, 2.0), panel = saturate(u.p1.z);
    float aspect = res.x / res.y;
    float2 p = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);     // screen heights, centred, y up
    float ts = t * speed;

    // ---- flow
    Studio5Flow F;
    F.fs = 2.1 / sc;
    // Oil spreads in a free surface with no gravity drainage to calm it: stronger eddies,
    // which fold its smooth thickness field into the streaks and tongues of a real slick.
    F.amp = (oil ? 0.30 : 0.18) * swirl * sc;
    float hb0 = 0.93 - 0.26 * drain;                         // black-film line (soap)
    F.hb = hb0;
    F.calmTop = oil ? 0.0 : 1.0;
    F.buoy = oil ? 0.0 : 0.05 * swirl;
    // The octaves drift in different directions, so the eddies evolve as well as travel:
    // a weather map in slow motion. Oil also rides a steady current to the right.
    float cur = oil ? -0.0060 : 0.0;
    F.o1 = ts * float2(-0.0026 + cur * F.fs, 0.0007) + float2(3.1, 7.7);
    F.o2 = ts * float2(0.0030 + cur * F.fs * 2.13, 0.0042) + float2(11.4, 2.9);
    float2 q = studio5_advect(p, F);
    // gentle buoyancy at the bottom margin: the film there is drawn from a little lower
    // (a C1 ramp: a kinked one would crease the bands along a line)
    q.y -= F.buoy * (1.0 - smoothstep(-0.30, 0.35, q.y + 0.5));
    float h = q.y + 0.5;

    // ---- plumes: thin patches breaking off the bottom margin and rising (soap), or drifting
    // with the current (oil), over ~60 s, broadening, faded in and out. Five staggered slots,
    // each respawning every 145–193 s at a fresh spot: one new plume every ~30 s on average.
    // A plume is a soft patch of thin film — dark (≈25 nm) or first-order gold (≈175 nm) —
    // blended in log thickness by `pw`, so its flank shows the interference orders between
    // it and the film around it as soft rings; around it the stratification is lifted
    // (`bulge`), so the bands arch over the rising head like smoke over a thermal.
    // It rides a sixth of the flow's displacement: bent by it, but not sheared into threads
    // by the strong eddies at the margin.
    float2 qp = mix(p, q, 0.16);
    float bulge = 0.0, pw = 0.0, plt = 0.0;
    if (plumes > 0.0) {
        for (int i = 0; i < 5; ++i) {
            float fi = float(i);
            float P = 145.0 + 12.0 * fi;                             // slot period, s
            float ph = ts + P * fract(fi * 0.618034 + 0.31);
            float cyc = floor(ph / P), tau = ph - cyc * P, s = tau * (1.0 / 60.0);
            if (s >= 1.0) continue;                                  // uniform: idle slot
            // successive spawns of a slot walk a low-discrepancy sequence: well spread out
            float hx = fract(cyc * 0.7548777 + fi * 0.5698403);
            float x0 = (hx - 0.5) * aspect * 0.85;
            float wob = 0.03 * sin(tau * 0.19 + fi * 2.1);
            float2 c = oil ? float2((hx - 0.5) * aspect * 0.9 + 0.36 * (s - 0.5) * sc,
                                    (fract(hx * 3.7) - 0.5) * 0.8 + wob)
                           : float2(x0 + wob, -0.62 + 0.55 * s);
            float sg = (0.06 + 0.07 * s) * sc;
            float fo = sin(3.14159265 * s * (1.25 - 0.25 * s));          // in by s≈0.25, out slowly
            float amp = plumes * fo * fo;
            float2 dq = (qp - c) * float2(1.0, 1.2);                 // a little wider than tall
            float r2 = dot(dq, dq) / (sg * sg);
            if (r2 < 9.0) {                                          // exp(−9): nothing left
                float w = amp * exp(-r2);
                float tl = oil ? 4.0 : (fract(hx * 7.31) < 0.4 ? 3.2 : 5.16);   // log nm
                plt += w * tl; pw += w;
                bulge += w * sg;
            }
        }
    }

    // ---- thickness (log nm) in the pre-advection frame
    float ld, hb = 0.0;
    if (!oil) {
        // Black-film line: drainage sets it; it breathes over ~30 s, and hangs in rounded
        // scallops (cusps between them) of uneven width that drift along it.
        float xs = q.x * (5.0 / sc);
        float sx = sin(xs + 0.9 * sin(xs * 0.43 + ts * 0.011) + ts * 0.013);
        hb = hb0 + 0.012 * sin(ts * 0.2027 + 1.3) + 0.006 * sin(ts * 0.1337 + 4.0)
           - 0.024 * sqrt(sx * sx + 0.015);
        // Drainage profile: ~linear through the strong 1st–3rd orders, then thickening
        // faster toward the bottom, where the high orders wash out to silvery white.
        float dx = hb - h + bulge;
        // soft max(dx, 0); Scale zooms the eddies fully but the band ladder only by √scale,
        // so a close or wide view still spans the strong orders
        float x = 0.5 * (dx + sqrt(dx * dx + 1e-4)) * rsqrt(sc), xt = max(x - 0.42, 0.0);
        ld = log(70.0 + 1150.0 * x + 1000.0 * xt * xt);
    } else {
        // Oil: streaks drawn out along the current (to the right), ~90–900 nm: bronze and
        // violet where thin, teal and the second orders where it pools.
        float2 o = (q - float2(0.0, bulge)) / sc + float2(-0.0060 * ts, 0.0);
        float f = studio5_noise(o * float2(0.8, 2.2) + float2(1.7, 4.2))
                + 0.55 * studio5_noise(o * float2(1.7, 4.6) + float2(7.3, 1.1))
                + 0.25 * studio5_noise(o * float2(3.6, 9.0) + float2(3.3, 9.4));
        ld = log(mix(330.0, 200.0, drain)) + 1.2 * f;
    }
    if (pw > 0.0) ld = mix(ld, plt / pw, min(pw, 1.0));
    // one fine octave of thickness turbulence where the film is thick: it ruffles the pale
    // high orders (in the vivid ones, plume rims included, it would serrate every band edge)
    if (!oil && ld > 6.4) {                                          // log 600 … log 1300 nm
        float turb = studio5_noise(q * (11.0 / sc) + float2(0.0, -0.012 * ts) + 19.0);
        ld += 0.08 * turb * smoothstep(6.4, 7.15, ld);
    }
    if (!oil) {
        // Newton black film (6.5 nm) above the line. It is the lightest film there is: a
        // strong eddy may fold it down a little way, never deep into the thick film (there it
        // stays the silvery thin film it borders on).
        float m = smoothstep(hb - 0.010, hb + 0.012, h) * smoothstep(hb0 - 0.42, hb0 - 0.20, p.y + 0.5);
        ld = mix(ld, 1.87, m);
    }
    float d = exp(ld);
    float gd = length(float2(dfdx(d), dfdy(d)));

    // ---- light: a big soft panel behind the camera, seen in the (slightly bowed) film
    float r2p = dot(p, p);
    float2 sp = p * (1.0 + 0.10 * r2p);                     // bow: reflection a touch barrel-shaped
    float2 hw = float2(0.5 * aspect, 0.5) * mix(0.82, 1.45, panel);
    const float rad = 0.20;
    float2 qd = abs(sp) - (hw - rad);
    float sdf = length(max(qd, 0.0)) + min(max(qd.x, qd.y), 0.0) - rad;   // < 0 inside
    float soft = mix(0.10, 0.20, panel);
    float win = 1.0 - smoothstep(-soft, soft * 0.7, sdf);
    float ed = (sdf + soft * 0.35) / (soft * 0.45);
    float Lp = (win + 0.10 * exp(-ed * ed)) / (1.0 + 1.2 * r2p) + 0.012;
    // Amplitude reflection coefficients: air|soap|air ±0.1416 (the π shift makes d → 0
    // black); air|oil|water −0.200, +0.060. A, B = the Airy line through R(cos δ = ±1).
    float n = oil ? 1.50 : 1.33;
    float sinI = 0.32 * sqrt(r2p);
    float nc = n * sqrt(1.0 - sinI * sinI / (n * n));                // n cos θt
    float A = oil ? 0.043053 : 0.038540, B = oil ? -0.023000 : -0.038540;
    float3 R = studio5_film(d * nc, gd * nc, A, B);
    // out-of-gamut (negative) channels pull toward the luminance, never clip to neon
    const float3 LUM = float3(0.2126, 0.7152, 0.0722);
    float Y = dot(R, LUM), mn = min(R.r, min(R.g, R.b));
    if (mn < 0.0) R = mix(R, float3(Y), saturate(-mn / max(Y - mn, 1e-6)));
    R = Y + (R - Y) * 0.72;

    // Oil: the camera exposes for the colour, so most of plain water's 2% glare goes to black.
    if (oil) R = max(R - 0.015, 0.0) * 1.35;
    float3 col = studio5_lin(u.colorA.rgb) + R * (Lp * 8.0) * studio5_lin(u.colorB.rgb);
    // filmic: ACES on luminance (hue-preserving) mixed with per-channel ACES for the shoulder
    float L = dot(col, LUM);
    float3 tm = mix(col * (aces(float3(L)).x / max(L, 1e-6)), aces(col), 0.6);
    float3 o = linearToSrgb(saturate(tm));
    // one hash: ±1 LSB dither everywhere, plus the lightest grain in the blacks (white,
    // triangular, re-seeded at 24 fps: reads as film grain, never as a pattern)
    float3 hg = pcg3(float3(px, floor(t * 24.0)));
    float dark = 1.0 - smoothstep(0.0, 0.25, dot(o, LUM));
    o += (hg.x + hg.y - 1.0) * (1.5 / 255.0 + 0.006 * dark);
    return float4(o, 1.0);
}

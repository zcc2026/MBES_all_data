function [navigation, Xdata] = read_all_x(filename)
% READ_ALL_X  从Kongsberg .all文件中提取所有X（深度）数据包



fid = fopen(filename, 'rb');
if fid == -1
    error('无法打开文件：%s', filename);
end

% 初始化输出结构体数组（动态扩充）
Xdata = struct('datetime', {}, 'heading', {},'across', {}, 'along', {});

idx = 0;  % 记录计数
idx2 = 0;
navigation = [];
selectedDescriptor = [];
f = 0;
x_depth = [];
while ~feof(fid)
    % ---- 读取记录长度（4字节，不含自身） ----
    len = fread(fid, 1, 'uint32', 0, 'ieee-le');
    if isempty(len), break; end
    if len < 12  % 无效记录，跳过
        fseek(fid, len, 'cof');
        continue;
    end
    
    % ---- 读取公共头部（12字节：STX, Type, Model, Date, Time_ms） ----
    stx  = fread(fid, 1, 'uint8');
    type = fread(fid, 1, 'uint8');
    model= fread(fid, 1, 'uint16', 'ieee-le');
    date = fread(fid, 1, 'uint32', 'ieee-le');      % YYYYMMDD
    time_ms = fread(fid, 1, 'uint32', 'ieee-le');   % 毫秒（UTC）
    
    % ---- 若为'X'类型（ASCII 88），解析完整数据 ----
    if type == 88
        % 读取X专用头部
        counter = fread(fid, 1, 'uint16', 'ieee-le');
        serial  = fread(fid, 1, 'uint16', 'ieee-le');
        heading = fread(fid, 1, 'uint16', 'ieee-le') / 100;      % 0.01°
        soundvel= fread(fid, 1, 'uint16', 'ieee-le') / 10;       % 0.1 m/s
        transDepth = fread(fid, 1, 'float32', 'ieee-le');        % 米
        nbeams  = fread(fid, 1, 'uint16', 'ieee-le');
        nvalid  = fread(fid, 1, 'uint16', 'ieee-le');
        sampleFreq = fread(fid, 1, 'float32', 'ieee-le');
        scanInfo= fread(fid, 1, 'uint8');
        spare1  = fread(fid, 1, 'uint8');
        spare2  = fread(fid, 1, 'uint8');
        spare3  = fread(fid, 1, 'uint8');
        
        % 预分配波束数据
        depth   = zeros(nbeams, 1);
        across  = zeros(nbeams, 1);
        along   = zeros(nbeams, 1);
        quality = zeros(nbeams, 1);
        incAngle= zeros(nbeams, 1);
        refl    = zeros(nbeams, 1);
        
        % 循环读取每个波束（每个波束固定大小）
        for i = 1:nbeams
            depth(i)   = fread(fid, 1, 'float32', 'ieee-le');
            across(i)  = fread(fid, 1, 'float32', 'ieee-le');
            along(i)   = fread(fid, 1, 'float32', 'ieee-le');
            detWinLen  = fread(fid, 1, 'uint16', 'ieee-le');
            quality(i) = fread(fid, 1, 'uint8');
            incAngle(i)= fread(fid, 1, 'uint8') / 10;   % 0.1°
            detInfo    = fread(fid, 1, 'uint8');
            realClean  = fread(fid, 1, 'int8');
            refl(i)    = fread(fid, 1, 'int16', 'ieee-le') / 10;  % 0.1 dB
        end
        
        % 读取尾部（1字节系统描述符 + ETX + 校验和）
        sysDesc = fread(fid, 1, 'uint8');
        etx     = fread(fid, 1, 'uint8');
        chksum  = fread(fid, 1, 'uint16', 'ieee-le');
        
        % 构造时间
        dt = datetime(num2str(date), 'InputFormat', 'yyyyMMdd', 'TimeZone', 'UTC') ...
             + seconds(time_ms / 1000);
        epoch = datetime(1970,1,1);
        
        % 存入结构体
        idx = idx + 1;

        Xdata(idx).datetime = posixtime(dt)-posixtime(epoch);
        Xdata(idx).incAngle = incAngle;
        Xdata(idx).heading = heading;
        Xdata(idx).across = across;
        Xdata(idx).along = along;
        Xdata(idx).z = depth;
        Xdata(idx).BS = refl;

       
    elseif type == 80
            % ---- 读取P固定字段 ----
        counter = fread(fid, 1, 'uint16', 'ieee-le');
        serial  = fread(fid, 1, 'uint16', 'ieee-le');
        lat_raw = fread(fid, 1, 'int32', 'ieee-le');
        lon_raw = fread(fid, 1, 'int32', 'ieee-le');
        quality_raw = fread(fid, 1, 'uint16', 'ieee-le');
        speed_raw   = fread(fid, 1, 'uint16', 'ieee-le');
        course_raw  = fread(fid, 1, 'uint16', 'ieee-le');
        heading_raw = fread(fid, 1, 'uint16', 'ieee-le');
        descriptor  = fread(fid, 1, 'uint8');
        nBytes      = fread(fid, 1, 'uint8');

        % 读取可变数据
        if nBytes > 0
            dataBytes = fread(fid, nBytes, 'uint8');
            inputStr = native2unicode(dataBytes, 'ASCII');
        else
            inputStr = '';
        end

        % 处理可能存在的填充字节（当总长度为奇数时）
        % 已读字节数（不含开头的len和公共头？需精确计算）
        % 从STX开始到当前已读的字节数 = 1(stx)+1(type)+2(model)+4(date)+4(time_ms)+2(counter)+2(serial)+4(lat)+4(lon)+2(quality)+2(speed)+2(course)+2(heading)+1(descriptor)+1(nBytes)+nBytes
        % 但最好直接用剩余长度判断：len - (从STX开始已读字节数) 是否 > 3 (ETX+checksum)
        bytes_from_stx = 1+1+2+4+4 + 2+2+4+4+2+2+2+2+1+1 + nBytes; % 从stx到nBytes及数据
        if len - bytes_from_stx > 3
            % 存在spare字节
            spare = fread(fid, 1, 'uint8');
        end

        % 读取尾部 ETX 和校验和
        etx = fread(fid, 1, 'uint8');
        chksum = fread(fid, 1, 'uint16', 'ieee-le');

        % 转换物理值
        latitude  = lat_raw / 20000000.0;
        longitude = lon_raw / 10000000.0;
        quality_cm = quality_raw;
        speed_mps  = speed_raw / 100.0;
        course_deg = course_raw / 100.0;
        heading_deg= heading_raw / 100.0;
%         fprintf('原始 date = %u, time_ms = %u\n', date, time_ms);
        % 构造datetime
        dt = datetime(num2str(date), 'InputFormat', 'yyyyMMdd', 'TimeZone', 'Asia/Shanghai') ...
             + seconds(time_ms/1000);
         epoch = datetime(1970,1,1);
        % 存入结构体
%         idx2 = idx2 + 1;
        newRow = [posixtime(dt)-posixtime(epoch), latitude, longitude];
        if isempty(selectedDescriptor)
            selectedDescriptor = descriptor;   % 使用第一个
        end
        if descriptor == selectedDescriptor
            navigation = [navigation; newRow];
            f = 1;
        end
        
    elseif type == 107
        disp("有k类型的报文")

    else
        % 非X数据包：跳过剩余部分（总长度len - 已读12字节）
        remaining = len - 12;
        if remaining > 0
            fseek(fid, remaining, 'cof');
        end
    end

end

fclose(fid);
fprintf('成功提取 %d 个X数据包。\n', idx);
end
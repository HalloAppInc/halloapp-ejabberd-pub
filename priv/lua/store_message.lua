local OfflineMessage = redis.call('EXISTS', KEYS[2])
if OfflineMessage == 0 then
	local OrderId = redis.call('INCR', KEYS[1])
	redis.call('HSET', KEYS[2], 'tuid', ARGV[1], 'm', ARGV[2], 'ct', ARGV[3], 'rc', 1, 'ord', OrderId, 'pb', ARGV[7])
	if ARGV[4] == 'undefined' then
	else
	    redis.call('HSET', KEYS[2], 'fuid', ARGV[4])
	end
	if ARGV[8] == 'undefined' then
	else
	    redis.call('HSET', KEYS[2], 'thid', ARGV[8])
	end
	redis.call('ZADD', KEYS[3], OrderId, ARGV[5])
	redis.call('EXPIRE', KEYS[2], ARGV[6])
	redis.call('EXPIRE', KEYS[3], ARGV[6])
end
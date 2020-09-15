local OrderId = redis.call('INCR', KEYS[1])
redis.call('HSET', KEYS[2], 'tuid', ARGV[1], 'm', ARGV[2], 'ct', ARGV[3], 'rc', 1, 'ord', OrderId)
if ARGV[4] == 'undefined' then
else
    redis.call('HSET', KEYS[2], 'fuid', ARGV[4])
end
redis.call('ZADD', KEYS[3], OrderId, ARGV[5])

package leader_test

import (
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/supertylerc/scheduler/pkg/leader"
)

func TestNewRedisLeader(t *testing.T) {
	t.Parallel()

	ctx := leader.Ctx

	miniServer := miniredis.RunT(t)
	defer miniServer.Close()

	// Set up miniredis client no leader
	miniClient := redis.NewClient(&redis.Options{
		Addr:       miniServer.Addr(),
		ClientName: "testclient1",
	})

	err := miniClient.Set(ctx, "leader:uuid", "key", leader.LeaderTTL).Err()
	if err != nil {
		t.Errorf("Failed to set initial key/value")
	}

	miniServer.FastForward(leader.LeaderTTL)

	ldr, _ := leader.NewRedisLeader(miniClient, "leader:uuid")

	tests := []struct {
		name  string
		input string
		ldr   *leader.RedisLeader
		want  bool
	}{
		{
			name:  "Become the leader",
			input: "leader:uuid",
			ldr:   ldr,
			want:  true,
		},
		{
			name:  "Not the leader",
			input: "",
			ldr:   ldr,
			want:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, _ := tt.ldr.IsCurrentLeader()
			if got != tt.want {
				t.Errorf("IsCurrentLeader() = %v, want %v", got, tt.want)
			}
		})
	}
}

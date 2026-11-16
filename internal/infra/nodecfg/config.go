// Package nodecfg 管理 agentd.yaml 配置的加载与原子写。
package nodecfg

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"

	"ir-edge/internal/domain/agentd"
)

// AgentDef 是 domain 类型别名（yaml 标签来自 domain）。
type AgentDef = agentd.AgentDef

// Config 是 agentd.yaml 的根结构。
type Config struct {
	Server  string     `yaml:"server" json:"server"`
	Cluster string     `yaml:"cluster,omitempty" json:"cluster,omitempty"`
	Port    int        `yaml:"port,omitempty" json:"port,omitempty"`
	Agents  []AgentDef `yaml:"agents" json:"agents"`
}

// Load 读配置并填默认值。
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, err
	}
	if cfg.Server == "" || len(cfg.Agents) == 0 {
		return nil, fmt.Errorf("config requires server and at least one agent")
	}
	if cfg.Port == 0 {
		cfg.Port = 7800
	}
	for i := range cfg.Agents {
		a := &cfg.Agents[i]
		if a.Slug == "" || a.Key == "" || len(a.Exec) == 0 {
			return nil, fmt.Errorf("agents[%d] requires slug, key, exec", i)
		}
		if a.Capacity <= 0 {
			a.Capacity = 1
		}
		if a.TimeoutSecs <= 0 {
			a.TimeoutSecs = 600
		}
	}
	return &cfg, nil
}

// Save 原子写。
func Save(path string, cfg *Config) error {
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

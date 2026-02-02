#!/bin/bash
set -euo pipefail

# 脚本功能：基于.gitignore规则，仅清理指定提交节点后的仓库历史中被忽略的文件
# 目标提交节点：31cde9bbf260147e29b591a4905d9580852a0b34
# 兼容所有git filter-repo版本（无需--refspec参数）
# 注意：执行前请确保代码已提交/备份，filter-repo会重写历史（不可逆）

# ===================== 可配置参数 =====================
# 要保留的提交节点（此节点及之前的历史不清理）
TARGET_COMMIT="31cde9bbf260147e29b591a4905d9580852a0b34"
# 当前要清理的分支（默认main，可根据实际修改）
TARGET_BRANCH="features/ai-agent"
# ======================================================

# 检查是否在git仓库根目录
if [ ! -d .git ]; then
    echo "❌ 错误：请在Git仓库的根目录执行此脚本！"
    exit 1
fi

# 检查.gitignore文件是否存在
if [ ! -f .gitignore ]; then
    echo "❌ 错误：当前目录未找到.gitignore文件！"
    exit 1
fi

# 检查git filter-repo是否安装
if ! command -v git-filter-repo &> /dev/null; then
    echo "❌ 错误：未安装git filter-repo，请先安装！"
    echo "安装方式参考："
    echo "  - macOS: brew install git-filter-repo"
    echo "  - Ubuntu/Debian: apt install git-filter-repo"
    echo "  - 通用方式: pip install git-filter-repo"
    exit 1
fi

# 检查指定的提交节点是否存在
if ! git rev-parse --quiet --verify "$TARGET_COMMIT" > /dev/null; then
    echo "❌ 错误：指定的提交节点 $TARGET_COMMIT 不存在！"
    echo "请检查提交哈希是否正确，或执行 git log 确认有效节点。"
    exit 1
fi

# 检查目标分支是否存在
if ! git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    echo "❌ 错误：指定的分支 $TARGET_BRANCH 不存在！"
    echo "请修改脚本中的 TARGET_BRANCH 变量为实际分支名（如master、main）。"
    exit 1
fi

# 检查仓库是否为干净状态
if [ -n "$(git status --porcelain)" ]; then
    echo "❌ 错误：仓库存在未提交的修改！"
    echo "请先提交或暂存所有修改（git add . && git commit -m 'backup'）。"
    exit 1
fi

# 高危操作确认
echo "⚠️  警告：此操作会重写 $TARGET_BRANCH 分支中 $TARGET_COMMIT 节点后的Git历史，且不可逆！"
echo "⚠️  执行前请确保："
echo "   1. 所有修改已提交（git status 显示 clean）"
echo "   2. 已备份仓库（cp -r 仓库目录 仓库备份目录）"
echo "   3. 了解历史重写对协作的影响（需强制推送）"
read -p "✅ 确认继续执行？(输入 yes 确认)：" confirm
if [ "$confirm" != "yes" ]; then
    echo "🔴 操作已取消！"
    exit 0
fi

# 读取.gitignore，过滤注释、空行、空白行，提取有效规则
echo -e "\n📄 正在解析.gitignore中的有效忽略规则..."
valid_rules=$(grep -v '^#\|^$\|^[[:space:]]*$' .gitignore | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# 检查是否有有效规则
if [ -z "$valid_rules" ]; then
    echo "ℹ️  .gitignore中无有效忽略规则，无需执行清理操作！"
    exit 0
fi

# 生成filter-repo的排除规则文件（临时文件）
exclude_file=$(mktemp)
echo "# 自动生成的.gitignore排除规则" > "$exclude_file"
while IFS= read -r rule; do
    if [ -n "$rule" ]; then
        echo "$rule" >> "$exclude_file"
    fi
done <<< "$valid_rules"

echo -e "\n🚀 开始处理分支：$TARGET_BRANCH"
echo "🔍 本次清理的规则列表："
cat "$exclude_file"

# ========== 核心逻辑：分步骤清理指定提交后的历史 ==========
# 1. 创建临时分支，指向目标提交（保留该节点及之前的历史）
echo -e "\n📌 步骤1：创建临时分支保留目标提交前的历史..."
git checkout -b temp_clean_base "$TARGET_COMMIT"

# 2. 分离出目标提交后的提交记录（创建临时工作分支）
echo -e "\n📌 步骤2：分离目标提交后的提交记录..."
git checkout "$TARGET_BRANCH"
git checkout -b temp_clean_work

# 3. 重写temp_clean_work分支的历史（仅清理该分支，保留其他分支）
echo -e "\n📌 步骤3：清理temp_clean_work分支中被忽略的文件..."
git filter-repo \
    --force \
    --invert-paths \
    --paths-from-file "$exclude_file" \
    --refs "refs/heads/temp_clean_work"

# 4. 合并清理后的分支回原分支
echo -e "\n📌 步骤4：替换原分支为清理后的版本..."
git checkout "$TARGET_BRANCH"
git reset --hard temp_clean_work

# 5. 删除临时分支
echo -e "\n📌 步骤5：清理临时分支..."
git branch -D temp_clean_base
git branch -D temp_clean_work

# ========== 收尾操作 ==========
# 清理临时文件
rm -f "$exclude_file"

# 清理冗余对象，减小仓库体积
echo -e "\n🧹 清理仓库冗余对象，优化体积..."
git reflog expire --expire=now --all
git gc --prune=now --aggressive

echo -e "\n🎉 仓库历史清理完成！"
echo -e "\n📌 后续操作建议："
echo "   1. 检查清理结果：git log $TARGET_COMMIT..$TARGET_BRANCH --stat"
echo "   2. 强制推送到远程仓库（谨慎！）：git push origin --force $TARGET_BRANCH"
echo "   3. 若有多个分支需清理，修改脚本中的 TARGET_BRANCH 后重新执行"
echo "   4. 其他协作者需重新克隆仓库，或执行：git pull --rebase --force"
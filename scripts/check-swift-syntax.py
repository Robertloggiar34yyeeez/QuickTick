import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent/'parser-deps'))
from tree_sitter import Language, Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
root=Path(__file__).resolve().parents[1]
errors=[]
files=list((root/'ios-starter').rglob('*.swift'))
for file in files:
    data=file.read_bytes()
    tree=parser.parse(data)
    def inspect(node):
        if node.type=='ERROR' or node.is_missing: errors.append(f'{file.relative_to(root)}:{node.start_point.row+1}: {node.type}: {data[node.start_byte:node.end_byte][:120]!r}')
        for child in node.children: inspect(child)
    inspect(tree.root_node)
if errors: print('\n'.join(errors)); sys.exit(1)
print(f'PASS: parsed {len(files)} Swift files with tree-sitter; this is syntax checking, not Apple type checking or xcodebuild.')

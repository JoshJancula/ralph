import '../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { PlanParserService } from './plan-parser.service';

describe('PlanParserService', () => {
  let service: PlanParserService;

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(PlanParserService);
  });

  describe('classic markdown plans', () => {
    it('should detect classic format', () => {
      const content = '# Plan\n- [ ] First task\n- [ ] Second task';
      const parsed = service.parsePlan(content);
      expect(parsed.format).toBe('classic');
    });

    it('should extract open todos', () => {
      const content = '# Plan\n- [ ] First task\n- [ ] Second task';
      const parsed = service.parsePlan(content);
      expect(parsed.todos).toHaveLength(2);
      expect(parsed.todos[0]).toMatchObject({
        type: 'classic',
        completed: false,
        content: 'First task',
      });
      expect(parsed.todos[1]).toMatchObject({
        type: 'classic',
        completed: false,
        content: 'Second task',
      });
    });

    it('should extract completed todos', () => {
      const content = '- [x] Done task\n- [ ] Open task';
      const parsed = service.parsePlan(content);
      expect(parsed.todos).toHaveLength(2);
      expect(parsed.todos[0].completed).toBe(true);
      expect(parsed.todos[1].completed).toBe(false);
    });

    it('should count completed and total todos', () => {
      const content = '- [x] Done 1\n- [x] Done 2\n- [ ] Open 1';
      const parsed = service.parsePlan(content);
      expect(parsed.completedCount).toBe(2);
      expect(parsed.totalCount).toBe(3);
    });

    it('should capture multi-line todo blocks', () => {
      const content = [
        '- [ ] First task',
        '  Additional details',
        '  More info',
        '- [ ] Second task',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.todos).toHaveLength(2);
      expect(parsed.todos[0].fullBlock).toContain('Additional details');
      expect(parsed.todos[0].fullBlock).toContain('More info');
    });

    it('should handle todos with varying whitespace', () => {
      const content = [
        '- [ ] First',
        '  - [ ] Nested (not treated as separate)',
        '  - [ ] item',
        '- [x] Second',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.todos.length).toBeGreaterThan(0);
      expect(parsed.todos.some((t) => t.content.includes('First'))).toBe(true);
    });

    it('should not match malformed checkboxes', () => {
      const content = '- [] No space\n- [x] Valid\n- [ ] Open';
      const parsed = service.parsePlan(content);
      expect(parsed.todos.length).toBe(2);
      expect(parsed.todos[0].content).toContain('Valid');
    });
  });

  describe('YAML frontmatter plans', () => {
    it('should detect YAML format', () => {
      const content = [
        '---',
        'name: Test Plan',
        'todos:',
        '  - id: task1',
        '    content: First task',
        '---',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.format).toBe('yaml');
    });

    it('should extract YAML metadata', () => {
      const content = [
        '---',
        'name: My Plan',
        'overview: Plan overview',
        'isProject: true',
        'mode: standard',
        'todos:',
        '  - id: task1',
        '    content: First',
        '---',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.metadata.name).toBe('My Plan');
      expect(parsed.metadata.overview).toContain('overview');
      expect(parsed.metadata.isProject).toBe(true);
      expect(parsed.metadata.mode).toBe('standard');
    });

    it('should extract YAML todos', () => {
      const content = [
        '---',
        'todos:',
        '  - id: task1',
        '    content: First task',
        '    status: pending',
        '  - id: task2',
        '    content: Second task',
        '    status: completed',
        '---',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.todos).toHaveLength(2);
      expect(parsed.todos[0]).toMatchObject({
        type: 'yaml',
        id: 'task1',
        content: 'First task',
        completed: false,
      });
      expect(parsed.todos[1]).toMatchObject({
        type: 'yaml',
        id: 'task2',
        content: 'Second task',
        completed: true,
      });
    });

    it('should recognize completed status values', () => {
      const statuses = ['completed', 'complete', 'done', 'Completed', 'DONE'];
      for (const status of statuses) {
        const content = [
          '---',
          'todos:',
          `  - id: task1`,
          `    content: Task`,
          `    status: ${status}`,
          '---',
        ].join('\n');
        const parsed = service.parsePlan(content);
        expect(parsed.todos[0].completed).toBe(true, `status "${status}" should be recognized as done`);
      }
    });

    it('should handle YAML todos with verification', () => {
      const content = [
        '---',
        'todos:',
        '  - id: task1',
        '    content: Test',
        '    verification: |',
        '      Run some tests',
        '---',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.todos[0]).toMatchObject({
        id: 'task1',
        verification: 'Run some tests',
      });
    });

    it('should count completed and total YAML todos', () => {
      const content = [
        '---',
        'todos:',
        '  - id: task1',
        '    status: completed',
        '  - id: task2',
        '    status: pending',
        '  - id: task3',
        '    status: done',
        '---',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.completedCount).toBe(2);
      expect(parsed.totalCount).toBe(3);
    });
  });

  describe('artifact links', () => {
    it('should identify artifact references in classic plan content', () => {
      const content = '- [ ] Check artifact at `.ralph-workspace/artifacts/PLAN1/output.txt`';
      const parsed = service.parsePlan(content);
      expect(parsed.todos[0].content).toContain('artifact');
    });

    it('should preserve code blocks in classic todos', () => {
      const content = [
        '- [ ] Run command',
        '  ```bash',
        '  npm test',
        '  ```',
        '- [ ] Next task',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.todos[0].fullBlock).toContain('npm test');
    });
  });

  describe('edge cases', () => {
    it('should handle empty plans', () => {
      const parsed = service.parsePlan('');
      expect(parsed.todos).toHaveLength(0);
      expect(parsed.completedCount).toBe(0);
      expect(parsed.totalCount).toBe(0);
    });

    it('should handle plans with no todos', () => {
      const content = '# Just a heading\nSome content\nMore content';
      const parsed = service.parsePlan(content);
      expect(parsed.todos).toHaveLength(0);
    });

    it('should handle YAML without todos section', () => {
      const content = [
        '---',
        'name: Plan',
        'overview: Test',
        '---',
        'Regular content',
      ].join('\n');
      const parsed = service.parsePlan(content);
      expect(parsed.format).toBe('yaml');
      expect(parsed.todos).toHaveLength(0);
    });

    it('should handle mixed case checkbox markers', () => {
      const content = '- [X] Done\n- [ ] Open\n- [x] Also done';
      const parsed = service.parsePlan(content);
      expect(parsed.todos).toHaveLength(3);
      expect(parsed.completedCount).toBe(2);
    });

    it('should preserve raw content', () => {
      const content = '# Plan\n- [ ] Task';
      const parsed = service.parsePlan(content);
      expect(parsed.rawContent).toBe(content);
    });
  });
});
